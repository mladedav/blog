+++
title = "Rewriting `tracing_subscriber::reload` to panic less"
date = 2026-07-16
description = "I reimplement a tracing layer for reloading from the ground up, describing the implementation."
taxonomies = { tags = ["rust", "tracing"] }
+++

---

tl;dr

- I built an alternative to `tracing_subscriber::reload::Layer` because it had issues.
- This version panics less and hopefully does more of what users want.
- It leaks memory though.
---

## Upstream reload layer

When using `tracing`, you sometimes want to change some configuration of you logging. You might want
to dynamically change the log level because you've heard there are issues with you application and
you need more logs but do not want to restart the whole thing because of that. You might want to
change the domain or port where you send your OpenTelemetry traces. Or you might want to dynamically
switch between compact and pretty format of `tracing_subscriber::fmt::Layer`.

Any of these require changing the configuration you provided to `tracing`, usually at the start of
your application[^1].

There is a batteries-included solution for this in `tracing-subscriber` and if it works for you, great, go
use that. But there has been a few issues with it over the years. To list some:
- it doesn't work at all when your layers need to downcast ([example](https://github.com/tokio-rs/tracing-opentelemetry/issues/121)),
- it may make some layers panic when they've missed parts of span lifecycle ([example](https://github.com/tokio-rs/tracing/issues/3529) and [example](https://github.com/tokio-rs/tracing/issues/3511)),
- it makes per-layer-filters panic after reload ([example](https://github.com/tokio-rs/tracing/issues/1629) and [example](https://github.com/tokio-rs/tracing/issues/2499#issuecomment-1462542365)).

{% aside(speaker="red") %}
So instead of a blogpost write a PR against `tracing-subscriber`, make the world a better place and
everyone wins.
{% end %}

Yeah, I wish that was the way to go. But at the time of writing this, the `tracing` repository on
GitHub has 630 open issues and 230 open pull requests and there is not nearly enough qualified
reviewers.

And all of the issues would require a breaking change and since the layer in question lives in
`tracing-subscriber`, that would also mean a breaking release for pretty much the whole ecosystem
even if they don't use this layer.

So instead, I went ahead and rewrote it mostly from scratch. Well, trying to keep the API _similar_
where possible, but the logic is very different.

Of note in the original API is that we get the layer itself along with a `Handle` which is a struct
through which we can change the wrapped layer. The two methods for changing the layer are these:

```rust
impl<L, S> Handle<L, S> {
    pub fn reload(&self, new_value: impl Into<L>) -> Result<(), Error>
    pub fn modify(&self, f: impl FnOnce(&mut L)) -> Result<(), Error>
}
```

The first one is a simple replacement of the inner layer while the other allows users to update the
layer in place. Which is a great feature which we cannot keep soundly. More on that later, but this
is the outline of what we want our replacement layer and handle to look like.

So let's go through some of the issues with the original implementation and how the new one solves
it.

## Downcasting to inner layers

Motivating example here is [reloading the `tracing-opentelemetry`
layer](https://github.com/tokio-rs/tracing-opentelemetry/issues/121). For that, we need the
reloading layer to be able to downcast to the wrapped layer or whatever that allows us to downcast
to.

`tracing` implements downcasting through `unsafe fn Layer::downcast_raw(&self) -> Option<*const
()>`. It is mainly used by `Dispatch::downcast_ref` to go from a type-erased `Dispatch` to a
concrete `Subscriber` implementation or a layer or even something else entirely like
`tracing_opentelemetry::WithContext`.

{% aside(speaker="blue") %}
Why would it be useful to downcast to something _else_?
{% end %}

Because we can do that from a context where we have just the `Dispatch` and we don't know the exact
type of the `Layer`. For example in `tracing-opentelemetry`, the type is `OpenTelemetryLayer<S, T>`
where each of the generic parameters is bounded by something but we don't know them. It will usually
be `S = tracing_subscriber::registry::Registry` and `T = opentelemetry_sdk::trace::SdkTracer` but we
can't be sure. And we can't try to downcast to every possible type.

So instead, we downcast to something without generics which we can name from anywhere. And that in
turn can use other tricks to then name and use `S`.

### Upstream downcasting support while reloading

In `tracing_subscriber::reload::Layer`, it's non-existent by design.  From the official docs:

> The `Layer` implementation is unable to implement downcasting functionality,
so certain `Layer` will fail to downcast if wrapped in a `reload::Layer`.

And the implementation:

```rust
#[doc(hidden)]
unsafe fn downcast_raw(&self, id: TypeId) -> Option<*const ()> {
    // Safety: it is generally unsafe to downcast through a reload, because
    // the pointer can be invalidated after the lock is dropped.
    // `NoneLayerMarker` is a special case because it
    // is never dereferenced.
    //
    // Additionally, even if the marker type *is* dereferenced (which it
    // never will be), the pointer should be valid even if the subscriber
    // is reloaded, because all `NoneLayerMarker` pointers that we return
    // actually point to the global static singleton `NoneLayerMarker`,
    // rather than to a field inside the lock.
    if id == TypeId::of::<layer::NoneLayerMarker>() {
        unsafe { return try_lock!(self.inner.read(), else return None).downcast_raw(id) }
    }

    None
}
```

If you wonder what this `NoneLayerMarker` thing is, `tracing` is using it internally to figure out
if a wrapped layer is `Option::None` for filtering purposes. Oh, that's also another reason you
might want to downcast to some random type other than the layer itself! But it is completely
unrelated to what we want to achieve so I'm going to ignore it going forward.

In all this, the only relevant thing we found is this ominous safety sentence: "it is generally
unsafe to downcast through a reload, because the pointer can be invalidated after the lock is
dropped."

What they mean is that for the current stock implementation in `tracing-subscriber`, which is
basically `struct Layer(Arc<Mutex<InnerLayer>>)`, we cannot hand out pointers to the inner layer and
hope that no one deallocates the layer while the pointer might still be in use. Even just calling
`Handle::modify` and then doing nothing inside the closure would create a mutable reference to the
inner layer which would invalidate the pointer and the pointer's next dereference would be undefined
behavior.

### Downcasting made possible

Which has an obvious solution. We just never modify or deallocate the inner layer. Which sounds like
it completely defeats the whole point, but we can keep all the historical layers around but we still
let the user change what we consider the _active_ layer and we pass all calls to that one. If
someone still uses a pointer to an older inner layer, the thing might not do what they expected or
they get a stale or incomplete view into the system, but at least it's not UB.

{% aside(speaker="blue") %} So we're leaking memory for all layers? Or even other resources if the
layers open network connections or keep around open file descriptors? Can't we somehow detect that
the layer is not used anymore and free it?  {% end %}

Yes, we're leaking with every reload. That's the price of downcasting.

There is no way to find out when a pointer is dropped. Or when the reference which was passed to us
goes out of scope. Once we give out the pointer, we either need an `unsafe` side-channel telling us
it's now ok to invalidate the pointer or we have to do everything to keep it valid until the whole
`Layer` is dropped.

There might be some heuristics like "if all threads that got pointer X called the method again and
got pointer Y, no one is using the old one" but it's not bullet-proof. We could consider giving the
user an option to unsafely opt-into something like that, but it's still just a heuristic and anyone
can do stuff like caching the result of the `downcast_raw` call indefinitely. End-users sometimes do
weird stuff and it's not a good idea expecting them not to. And besides, the rules are that any
sequence of operations in safe Rust must not cause undefined behavior. So we just leak. Leaking is
memory safe.

If we're thinking of the original implementation as `struct Layer(Arc<Mutex<InnerLayer>>)` we can
think of the new one as `struct Layer(Arc<Mutex<Vec<InnerLayer>>>)`.

One unfortunate change to the API this necessitates is that we can't have `Handle::modify`.  As
noted earlier, just the creation of `&mut L` invalidates any `*const L` we might have given out
before.

We could change the mutable reference to a shared one and mandate that anyone wishing to reload
their layers needs interior mutability, but at that point they probably didn't even need this whole
reload thing. So people are stuck with `reload` which requires them to create a new inner layer from
scratch. We can provide them with a reference to the old one in case they can clone it, but we can't
do much more than that and the rest is on them.

{% aside(speaker="red") %}
To summarize, people can switch to this new crate but then they can't use the single most used
feature AND it leaks resources.
{% end %}

Well, yes. But it works with `tracing_opentelemetry`.

## Tracking span lifetime

The second issue is some layers are gimmicky about their state. Some don't like spans or events
which are children of spans they have never heard about. Some have internal sanity check counters of
enters and exits within each span in debug builds.

We have to draw a line somewhere though. If we want to be extremely cautious, we can route root
spans to the reloaded layer and then everything else to whatever handled their parent. I don't think
any layer could really object to that[^2], but for some applications, that could take pretty long for
the new layer to get anything. For example, I believe `h2` creates spans for the lifetime of the
whole connection, which can span any number of requests. And all its children would still be handled
by the old layer.

Alternatively, we could route everything pertaining to a given span to the layer that observed its
creation. If the layer needs to find information on a parent it has never seen, that might not work,
but the change-over will be somewhat faster. A layer that might be broken by this because it needs
to have observed the parent would be again `tracing-opentelemetry`. When a new span is created, it
looks for its parent and sets trace ID based on that so if it cannot find the additional
information, it will not be able to correctly correlate spans.

And of course we could do what `tracing_subscriber::reload::Layer` does and just route everything to
the latest active layer. If the layers can handle that, that might be for the best.

Or we can let the user decide through configuration because all of these make sense sometimes. They
just need to be mindful that some configurations may make some layers panic.

Either way, we just add a `HashMap<span::Id, usize>` which points into our vector of historical
layers. And then we decide if new spans should always route to the latest layer or we route them
based on their parent. But that's just a minor implementation detail.

## Per-layer-filter setup

{% aside(speaker="blue") %}
What exactly are these?
{% end %}

These are the filters you add by calling `Layer::with_filter` as opposed to adding global filters as
normal layers using `SubscriberExt::with`.

{% aside(speaker="blue") %}
And what's the difference there?
{% end %}

As the name suggests, per-layer-filters filter out stuff only for the layer they are attached to.
These are thing that implement the `Filter` trait which looks like the `Layer` trait, but isn't
exactly the same. The global filters influence all layers, if they decide that they don't want to
see something, no one gets to see it. The implementation is a classic `Layer` that usually provides
implementation just for stuff like `Layer::enabled` and `Layer::register_callsite`.

Per-layer-filters are somewhat complicated and were added into `tracing` much later than most of the
other stuff and they do have their peculiarities. They were built to be performant and there are
some rough edges where optimizations were done.

Somewhat good news for us is that `tracing_subscriber::registry::Registry` is the only subscriber
that handles per-layer-filters them and no one else can directly support them. It's a known
limitation that was supposed to be lifted one day, but that hasn't happened yet and probably will
not anytime soon. So whatever we do, we need to be compatible with only this one implementation and
its wrappers.

The way it works is that when you call `Layer::with_filter`, you get back a `Filtered` which is a
layer that handles the original layer and the provided filter. When it is added to a subscriber, its
`on_layer` method asks the subscriber for a `FilterId`. This ID is then used during the lifetime of
the program as a mask of a global `u64` to set a bit there to signal its filtering decision. The
subscriber then looks at that global state and if no one is interested in an event, it drops it.

{% aside(speaker="red") %}
Which parts are important for us?
{% end %}

Each `Filtered` needs to have its `on_layer` called to get its `FilterId`.

{% aside(speaker="red") %}
And if we don't?
{% end %}

It panics on first use because it has not been properly initialized.

Now the real problem here is, the signature is this:

```rust
trait Layer<S> {
    fn on_layer(&mut self, subscriber: &mut S);
    // Other stuff...
}
```

But we can't really have a mutable reference to the subscriber. This method is meant to be called
before the subscriber is ever registered and the whole program starts using it as a `&dyn
Subscriber`. As mentioned earlier, creating a mutable reference to something everyone uses that way
would be instant undefined behavior.

### Fake `Registry`

We've already touched on that the only thing supporting per-layer-filters would be a `Registry` or
something wrapping it because there is no other way to create a `FilterId`.

When the subscriber would call `on_layer` on our layer and we would call that on the inner layer and
the inner would get a `FilterId` from the real subscriber. And when we are to reload a layer, we
simply create a new `Registry` and our job would be to somehow make sure that the new layer gets the
same `FilterId` as the old one.

There are two issues with that, first, we don't know the `FilterId` so we don't know how to force a
registry to give out the same one. And second, the reloaded layer could have more filters than the
first one. For example the inner layer could be `Vec<Inner>`. On construction there is one inner
layer with a filter, on reload there are two. If we set up the registry to give out the `FilterId`
we wanted, the second layer would get one that is possibly already in use by some other unrelated
layer.

The first problem can be solved by getting the `FilterId`s before and after calling
`on_layer` on the inner layer and then figuring out what these are. What the registry hands out, are
basically numbers 0-63 which encode the bit offset the `FilterId` cares about[^3]. If we construct a
layer that does anything and we add a filter that always lets it happen, and then we wire that into
or make it clash with a subscriber that hands out its own `FilterId`s which always prohibit stuff
from happening, we just need to count how many layers it took for the subscriber to overwrite our
original decision.

For example if we have `FilterId(3)` (and we don't know that), if the subscriber hands out 3
filters, those will not clash. The next one would so if we're adding the filters one-by-one and keep
trying, we'll find the ID eventually.

Or we can simply depend on `FilterId`'s implementation of `Debug`.

{% aside(speaker="blue") %}
You shouldn't do that, it's explicitly not guaranteed not to change.
{% end %}

Yeah, I know. It's simple though. And cheaper. And it probably won't change. Yeah, let's do it and
hope for the best.

For the changing number of filters, there isn't much more to be done other than asking the user not
to do it or letting them configure how many `FilterId`s we additionally register with our layer so
that they can be used later. But we'll never know if we're using more than we're supposed to.

{% aside(speaker="blue") %}
How about we take one more again and used the same trick to check for that?
{% end %}

Ok, we can know but the filtering will most likely be broken as there is nothing we could do to fix
that.  Except for completely refusing to reload the layer.

But the biggest issue is, that this whole approach won't work.

{% aside(speaker="blue") %}
Wait what? Why did you make everyone read this then?
{% end %}

That's just the development process I guess. And we've learned stuff we can refer to later.

Anyways, the reason this won't work is because we can't guarantee that the layer we're wrapping
really implements `Layer<Registry>`. What we get is a type implementing `Layer<S>` for some concrete
`S` but it can be something else. For example in

```rust
tracing_subscriber::registry() // Returns `Registry`
    .with(LayerOne)            // Returns `Layered<LayerOne, Registry>`
    .with(LayerTwo)            // Returns `Layered<LayerTwo, Layered<LayerOne, Registry>>`
```

we need `LayerOne` to implement `Layer<Registry>` and `LayerTwo` to implement
`Layer<Layered<LayerOne, Registry>>` where `Layered` is the actual subscriber implementation. So if
we wrapped each of those with our reloading layer, we would be able to reload only the first one if
we had something like

```rust
impl Handle<L> {
    fn reload(&self, new: L)
    where
        L: Layer<Registry>,
    {
        // To be used later for `FilterId` generation...
        let fake = Registry::default();

        //...
    }
}
```

If we made `reload` generic over `S`, we would still need to somehow create the `S` and there's no
method for that. And who knows what side effects calling `register_filter` could have on that. Until
now, we could just check the `Registry` implementation to decide if something was fine to do, now we
would have to be much more pessimistic. So this is not the way.

We could go around that problem by forcing people to do this instead:

```rust
let layers = LayerOne          // Returns `LayerOne`
    .and_then(LayerTwo);       // Returns `Layered<LayerTwo, LayerOne, Registry>`
tracing_subscriber::registry() // Returns `Registry`
    .with(layers)              // Returns `Layered<Layered<LayerTwo, LayerOne, Registry>, Registry>`
```

But explaining to people why one works and the other doesn't would become a chore very quickly. And
preferably, whatever worked with the old `reload::Layer` should work here too so that people can
switch easily. So while a workaround exists, it's not very good.

### Fake Subscriber

Instead of using `Registry`, we can try using our own custom type. We will implement `Subscriber`
and `LookupSpan` on it and then use that as an argument to the `on_layer` method of the reloaded
layers.

{% aside(speaker="red") %}
You said no one can create a new per-layer-filter aware subscriber.
{% end %}

That is mostly true but of course anyone can create a newtype wrapping a `Registry` and calling it a
new subscriber implementation. Which is what we will do, except instead of just forwarding calls
into the `Registry`, we cache the handed out `FilterId`s for later use. And then when we reload the
layer, our fake subscriber can hand those out again and again. If they run out, it can hand out the
last one multiple times, breaking just parts of the reloaded layer but nothing else.

There are a few issues though, so let's tackle them one at a time:

#### `dyn Layer<OurFakeSubscriber>`

One issue with this is that we would now require any inner layer `L` to be reloaded to implement
`Layer<OurFakeSubscriber>`.  which would usually be ok, but there are layers such as `Box<dyn
Layer<S>>` which get the following blanket implementation

```rust
impl<S> Layer<S> for Box<dyn Layer<S> + Send + Sync> where S: Subscriber,
```

This will only be implemented for a single `S`. So if we have a `Box<dyn Layer<Registry>>` it will
not implement `Layer<OurFakeSubscriber>` but only `Layer<Registry>`.

This means that our users need to build `Box<dyn Layer<OurFakeSubscriber>>` instead and everything
should work fine.

Most other layers just do the following, so that's fine.

```rust
impl<S: Subscriber + for<'lookup> LookupSpan<'lookup>> Layer<S> for MyLayer {}
```

#### Building a `Context`

The next issue is that quite a few methods on `Layer<S>` take `Context<'_, S>` as an argument. This
is basically a wrapper around `&S`. And we can't create that because the only constructor is private
to `tracing-subscriber`. But we can be resourceful.

The private constructor is called by `Layered<L, S>` which is something wrapping a layer and a
subscriber. It's the thing you get whenever you call `registry().with(layer)`. Of course that type
needs to build the `Context` so that it can then call all the methods on the `Layer`. So let's
create a `Layered` with a layer that steals the `Context` and passes it anywhere we want.

And when I say steals, I really mean borrows because the type has a lifetime which would be valid
only while the method we got it in is executing. So we create a layer to which we provide the
callback we want to call with the `Context` and let the layer call it.

Something like this:
```rust
fn with_ctx<F, T>(&self, f: F) -> T
where
    F: FnOnce(Context<'_, OurFakeSubscriber>) -> T,
    T: 'static,
{
    type DynFnOnce<'a, T> = dyn FnOnce(Context<'_, OurFakeSubscriber>) -> T + 'a;
    struct ContextStealer<T>(
        Cell<Option<Box<DynFnOnce<'static, T>>>>,
        Cell<Option<T>>,
    );

    impl<T> tracing_subscriber::Layer<OurFakeSubscriber> for ContextStealer<T>
    where
        T: 'static,
    {
        // There's no reason we use this method specifically, we just need one that uses
        // `Context` and preferably one which takes arguments that are easy to construct.
        fn on_follows_from(
            &self,
            _span: &span::Id,
            _follows: &span::Id,
            ctx: Context<'_, OurFakeSubscriber>,
        ) {
            let callback = self.0.replace(None).unwrap();
            let result = callback(ctx);
            self.1.set(Some(result));
        }
    }

    let subscriber = OurFakeSubscriber::new();

    let boxed: Box<DynFnOnce<'_, T>> = Box::new(f);
    // SAFETY
    // The whole `'static` bound exists just so we can use the function inside the `Layer` which
    // has to be `'static` same as the `Subscriber` itself. We call the closure and after that drop
    // the subscriber before this is used for longer than it should be. There is no way for it to
    // escape the closure so it's fine to do this.
    let transmuted = unsafe {
        std::mem::transmute::<Box<DynFnOnce<'_, T>>, Box<DynFnOnce<'static, T>>>(boxed)
    };

    let layered = subscriber.with(ContextStealer::<T>(
        Cell::new(Some(transmuted)),
        Cell::new(None),
    ));
    // The span IDs are ignored, just pass anything inside. `Registry` doesn't do anything with
    // this and the only layer is the one that we use to steal the context. `OurFakeSubscriber`
    // ignores the first `record_follows_from` call instead of forwarding it to the inner
    // subscriber.
    layered.record_follows_from(&span::Id::from_u64(u64::MAX), &span::Id::from_u64(u64::MAX));

    layered
        .downcast_ref::<ContextStealer<T>>()
        .unwrap()
        .1
        .replace(None)
        .unwrap()
}
```

Attentive readers have noticed the `unsafe` block there. The only reason we have to do that is
because each `Layer` needs to be `'static` so that `Layered` is `'static` which is a prerequisite
for implementing `Subscriber`. Because the idea is usually to have `Subscriber` which lives for the
lifetime of the application. And then use `Dispatch` to downcast down to it so we need the type to
live for pretty long.

In our case, we don't really need that. We just want to create the subscriber, call one method on it
and then get rid of it. No `Dispatch`, no downcasting, etc. The closure will be called while it's
still valid and then once that ends, we can drop the subscriber.

There might also be other ways to do the promotion, preferably one without boxing and dynamic
dispatch, but this works and so we can use it for now.

#### Using a `Context`

We have created a `Context` with correct generics but what does it do really? It's passed into
`Layer` methods so that the implementations can do things like looking up current spans or parents
of events and spans. All of this is done by calling methods the wrapped subscriber. That means that
our fake subscriber has to act the same way as the real subscriber.

So instead of `OurFakeSubscriber` we get `OurFakeSubscriber<S>` and forward all calls to the inner.
Except for `LookupSpan::register_filter`, we're doing this whole thing just to override that one
method. And the first `record_follows_from` call which is our fake to call to get the context and
should be called just on the context-stealing layer.

This complicates our lives again in that we need to hold an instance or a static reference of the
inner subscriber wherever we want to create the fake one. And there isn't really a way to get an
owned instance so we need a static reference.

Similarly to our earlier `Context` trick, we actually don't need a static reference for any reason
other than that our subscriber will hold the reference but to implement `Subscriber`, the type needs
to be `'static`. So we will do a similar `transmute`.

We'll need the fake context, and therefore a reference to the real subscriber, in four places. The
first three are:
- `Layer::on_layer` implementation where we set up the inner layers for the first time, and
- `with_ctx` we've just created,
- `Handle::replace_with` where we want to call `on_layer` on the newly created reloaded layers.

The first one is fairly simple. We are called with `&mut S` so we can just transmute for lifetime
extension and we're done.

The other two are not provided with anything like that. The closest thing we have in `with_ctx` is a
`Context<'_, S>` but there is no way for us to extract the subscriber reference from that.

What we need to do here is a little trick where our layer stashes the `Dispatch` of this subscriber
on its `on_register_dispatch` implementation. This is called when a subscriber is registered in
pretty much all flows.

{% aside(speaker="blue") %}
Almost?
{% end %}

Yeah, it breaks if someone does something like this, e.g. for testing purposes:
```rust
let subscriber = registry().with(layer);
subscriber.event(...);
```

Which means we have to write tests properly too with `tracing::subscriber::with_default`. Or at
least a `Dispatch::new`.

Anyways, back to the task at hand. We stash the dispatch, downgrading it in the process to avoid
reference cycles[^4]. And then, when we need `&S`, we just upgrade it again (which can fail if the
subscriber has been de-registered, in which case we don't really care about the event anymore
anyway), then we downcast it to `S` (which theoretically can fail but shouldn't and if it does, we
probably don't care about the event either) and finally `transmute` the lifetime again.

#### Downcasting again

This change broke downcasting for `tracing-opentelemetry` again. We forced the generic parameter `S`
in `OpenTelemetryLayer<S, T>` to be our fake subscriber and in some scenarios the layer does this:

```rust
let subscriber = dispatch
    .downcast_ref::<S>()
    .expect("subscriber should downcast to expected type; this is a bug!");
```

The problem is our `Dispatch` downcasts to some `RealSubscriber` while the snippet is trying to
downcast to `OurFakeSubscriber<RealSubscriber>` which it can't.

Now if the `dispatch` came from `on_register_dispatch`, we can give it a fake `Dispatch` that would
downcast to anything we want including our fake subscriber. But that wouldn't be enough as we should
also support the `tracing-opentelemetry` method for obtaining OpenTelemetry context of a span
outside the layer:

```rust
pub fn get_otel_context(
    span_id: &span::Id,
    dispatch: &Dispatch
) -> Option<opentelemetry::Context>
```

This `Dispatch` will almost surely come either from another layer's `on_register_dispatch` or from
`tracing::dispatcher::get_default` where we don't control what's returned at all. The only way to
make this work would be for the reload layer itself to downcast to the fake subscriber. Which is
possible, but involves leaking the real `Dispatch` because we would be handing out pointers to a
fake subscriber which in turn holds a static reference to something else which will live only for as
long as the `Dispatch`. As established earlier, there's no way for us to know when we can invalidate
it so we need the `&'static S` to really be `'static` this time. Which should be easy with one more
leak of the `Dispatch` which holds the subscriber.

## `Filter` implementation

So far, we've only talked about implementing `Layer` but what if someone needs to reload `Filter`s?
As mentioned earlier, those are the per-layer-filters we can attach to other layers, global filters
would work as is with the `Layer` implementation.

In that case, I think they should just stick with `tracing_subscriber::reload::Layer`. It having the
`modify` method and `Filtered` having the `filter_mut` method makes it much more ergonomic when you
don't need downcasting or correct routing. Which filters usually don't need. And otherwise, you can
reload the whole `Filtered` layer. But if you do have a use case not covered by this, feel free to
reach out.

Well, that and when I tried to implement it naively in one of the first versions. There were some
panics and I still had to deal with the other per-layer-filters issues. So I've decided to cut it
for now and then I built up these totally true reasons why it's actually great it's not implemented.
Maybe one day.

## Future work

This needs a bit of polishing and benchmarking and optimizing around the leaks. For example, if no
one downcasted to a given layer instance and all its spans are closed, we could just drop it and
free some memory. But that's also an adventure for another day.

For now, I'm releasing the library in pretty much the state that's described here. If you wanted to
reload some layers and the stock implementation did not work out, give it a go. And if you feel like
it, give some feedback.

## Is this slop?

This is a bit of a FAQ style section but let's get this over with quickly.

I did use an LLM to write boilerplate, to bounce ideas off of and to convince myself that all that
`unsafe` stuff is in fact sound. The code is supposed to run on a machine so if the machine says
it's fine, then it surely is, right?

So let's roleplay the slop accusations.

{% aside(speaker="red") %}
It's just one commit, surely that's slop.
{% end %}

I don't believe people should look at how sausages are made. I iterated a bunch and then squashed
everything into a single commit. But if you really want to see the process and are willing to
believe me since you won't find the commits on GitHub, this is how the history looked like before
the squash:

```gitlog
* 9f501d1 fixup
* c830580 update tests
* 8430307 remove filter impl
* 14f180f add .gitignore
* da18824 fmt
* f10469e update tests
* 9f991fe fake subscriber again
* fb3b979 update tests. Oh reloading layered does not work. Great
* 608cabf update tests
* 7cd7bdd some updates fighting against jail
* 832b64e (dm/leaking-builder-reload) works and this time even with opentelemetry
* 6961d44 wip but everything works probably
* 534ebc7 tests cleanup
* 9b2d22c fix some tests
* 49a4ff3 wip continue last commit, still tests fail/hang
* 04a0466 wip layer filter reload with fake subscriber downcasting test fail & hang
* 0c03246 wip layer filter reload with fake subscriber todo context passthrough
* 90b81b8 wip layer downcasting with transmute
* 8e6d6a0 squash into init
* 4f00a45 impl with leaking manual clone
* 85d8b17 wip init
```

{% aside(speaker="red") %}
There are tests and comments in the code, that's a telltale sign of AI.
{% end %}

Just... No. I mean, it might have written some tests. I then deleted most of them because I don't
need ten tests for the same thing and I had to rewrite what was left. But I'd call anything that's
left my own work. Just look how many of the commits mention just test updates.

Also, one of the files contains this, I think that speaks for itself:

```rust
#![expect(missing_docs, reason = "We'll do it later.")]
```

{% aside(speaker="red") %}
You're using Rust2021, only AI does that for new projects.
{% end %}

This is getting silly. I'm not using edition 2021. My MSRV is 1.85 which is the first version with
edition 2024. And it's also the version installed on Trixie, the current Debian stable.

## Conclusion

I think we can end it here. If you have need for a reloadable layers, give this a go and reach out
with any feedback.

[^1]: Or you can just output all your logs and filter and transform them in
[Vector](https://vector.dev). And you may have a local OpenTelemetry proxy that you reconfigure and
your app does not have to know about it. And you may output JSON logs and use a bespoke script to
transform the lines to pretty-like format. You can, but you probably don't want to.

[^2]: There is `follows_from` which pairs to spans that might not have a common ancestor. Some
layers might not like seeing that call with an ID of a span they don't know about. But from what I
can tell, no one really uses that anyway. And if we really cared, we could filter this out when the
two spans were handled by different layers. But we don't, so we don't.

[^3]: The filter ID is already `1 << x` where `0 <= x < 64`but for all intents and purposes, that's
the same thing. That's bijection for you. There are also some `FilterId` which are bitwise ANDs and
ORs of other `FilterId`s but that's not important for us.

[^4]: See [here](https://docs.rs/tracing/0.1.44/tracing/trait.Subscriber.html#avoiding-memory-leaks)
for details.
