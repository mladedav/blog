+++
title = "Yet another 'Hey, I'm using NixOS' blogpost"
date = 2026-04-20
description = "The start of my NixOS journey with VMs and `deploy-rs`"
taxonomies = { tags = ["nixos", "raspberry-pi"] }
+++

---

tl;dr

- Run NixOS locally in QEMU
- Set up `deploy-rs` to update the system over SSH

---

Yes. I do have a NixOS system running _somewhere_, thanks so much for asking. This is probably
served from that system.

{% aside(speaker="magenta", name = "Future me") %}
It isn't. It's just GitHub Pages for now. But someday when I figure out where to get a cheap IP
address and figure out some tunneling maybe...
{% end %}

There's been about seven hundred such posts to date and this one will not be any better than any of
the other ones. For the most part, I'm not always entirely sure what I'm doing so some of the stuff
I write might be misleading information in which case please do reach out! It probably will not be
funnier than the funny blog posts either, and it'll be harder to read than those written by people
who know how to teach and write. But I still decided to write this, if not for anyone else's
benefit, than for my own to have something to get back to if I ever need it.

So to set the stage, I've got a few Raspberry Pi 3B+ boards lying around collecting dust. They
should do something useful like collecting dust while blinking led lights. Or receiving some data
from random sensors like dust particle sensors.  Or run a wifi for other IoT devices, or run a
personal server. Or all of the above. We'll see where this all leads eventually.

The goal is to have this all declaratively which nowadays usually means NixOS. There are a few ways
to get NixOS on the Pis with the easiest one would be...

## Installing Linux on Raspberry Pi by hand

...the easy path I will not be taking.

There are no obstacles in installing almost any Linux distribution designed for Pis in this day and
age.  You just flash an SD card with any distro you like, connect a monitor and a keyboard to the
Pi, set up wifi, then install NixOS from within and you're done.

Except if I wanted to do this all the easy way, I would stop with the random distro I happened to
have lying around. Also, I don't own an HDMI cable. Neither do I own a USB to serial port adapter.
And under no circumstances will I do stuff like timing how long the Pi is booting and then blindly
typing commands without a monitor to set up anything. I can almost hear someone trying to tell me
that there's no need for that because I can already configure the SD card to connect to my WiFi (or
just use an ethernet cable, which I do own) and just SSH into it for the initial setup and
reinstall.  But that sounds like a lot of manual steps and like any other developer, I'll happily
spend the next two months of my life automating a task that would have taken five minutes and I
wouldn't have to do it more than about five times in the next two years.

Instead, I want to be able to flash an SD card with the built NixOS system. But in order to run, we
must learn to walk. So now as the actual first step, we just set up a minimal NixOS system inside a
virtual machine.

As you might have figured out, this post will be mostly a lot of groundwork towards the ultimate
goal.

{% aside(speaker="orange") %}
So... are we going to put anything on the Raspberry Pi in this post?
{% end %}

Well, no, but maybe I'll write another one sometime later where I actually do it? Hey, it's going to
be interesting anyway.

## Virtual NixOS

### Base system

We'll start with a minimal flake defining a NixOS system with a little bit of additional config for
running the system in QEMU.

{% details(summary="flake.nix") %}
{{ include_code(path="assets/nixos/00_bare_vm/flake.nix", syntax="nix") }}
{% end %}

This can be built and then started with the following two commands:

```shell
nix build '.#nixosConfigurations.obsidian.config.system.build.vm'
./result/bin/run-nixos-vm
```

{% aside(speaker="blue") %}
If you want to get back your terminal, you can press `ctrl+a x` to stop the emulation.
{% end %}

Writing that is a bit cumbersome, so as the first step, we'll add `apps.x86_64-linux` to the flake
outputs so that the virtual machine runs when we call `nix run`.

{{ flake_and_diff(dir="01_nix_run_vm") }}

This will greet us with a login prompt. But the only user with login shell other than `nologin` is
root and if we look into `/etc/shadow`, there is a `!` instead of a hashed password which means
that a password cannot be used to log into this account.

So we need to add an account we can use and while we're at it, we'll set sudoers so that the user
can use password-less sudo and it is logged in automatically when the system starts.

{{ flake_and_diff(dir="02_hello_alice") }}

Now we have a working system with a user we can log into. You can play with it and look what's
there. To be honest, there isn't much, but the goal right now is not to have stuff running on the
system, it's just to have a system that maybe might someday run something useful.

{% aside(speaker="orange") %}
Did you seriously use "bob" as alice's password? You couldn't come up with a worse one, could you?
{% end %}

Yeah. I do hope anyone copying the code changes it to something else. I mean I assume most people
not named Alice are going to change the username anyway so they should also change the password. And
it's not like anyone needs to write the password into this system with auto-login and password-less
sudo so I hope it's something strong.

{% aside(speaker="orange") %}
And why don't you just use `agenix` like everyone else? Putting plaintext passwords into flakes is
bad practice you know.
{% end %}

That's the plan, eventually. I didn't have the time yet and the content seems complicated enough as
is right now. Working secret management is obviously a prerequisite before I can push any of my
configs anywhere on the Internet (like into GitHub as a backup) so it's fairly high on the TODO
list. There's a lot written about that topic on the Internet so if anyone is curious, they can just
find anything they need. But who knows, maybe I'll also write about what worked for me.

But enough about horrible passwords and bad practices, let's do something with the system!

### Continuous updates

I know the original goal was to have a way to create a headless system just flashing an SD card, but
we need to think further. Do I want to manually flash the card more than once? If you've been paying
any attention at all, the answer is obvious, so let's first get that out of the way.

I will be building the system on my x86_64 machine and I don't think my old weak Raspberry Pi would
be able to run `nixos-rebuild` so any updates and rebuilds will also have to happen remotely. I also
do not have NixOS running on my laptop (yet) so I can't do `nixos-rebuild --target-host` either.

What I landed on is `deploy-rs` because that seems to be something everyone seems to be using these
days. It will build the system on my laptop and then deploy it over SSH. And it turns out I'm not
the first person to write about this, who could have guessed.
[This](https://crystalwobsite.gay/posts/2025-02-09-deploying_nixos#writing-our-first-deployment)
post seems to cover mostly the same things but without QEMU and on DigitalOcean.And it also mentions
trusted publishing, so if this style isn't to your liking, you can go check there. Though if you
dislike the style here, I don't know how you got all the way here.

#### SSH

Which brings us to the next logical step, enabling SSH:

{{ flake_and_diff(dir="03_ssh") }}

QEMU is now configured to listen on port 2222 and pass anything it receives there to the VM on port
22 where SSH is listening. So to connect to it from your host machine, you have to run
`ssh alice@localhost -p 2222`.

{% aside(speaker="blue") %}
If you're following along, don't forget to change the authorized public SSH key.
{% end %}

{% aside(speaker="orange") %}
SSH is telling me something nasty is happening.
{% end %}

If that happens, you've already connected to another host on `localhost` on port 2222 and SSH
helpfully remembered the public key that host used. Which might happen just because you happened to
rebuild the system here multiple times without keeping the qcow filesystem QEMU generated. From
SSH's point of view, this looks exactly like a man-in-the-middle attack where someone tries to
pretend they're your SSH server on localhost but they're not.

You can run `ssh-keygen -R '[localhost]:2222'` to make SSH forget the older system or use options
like `-o "UserKnownHostsFile=/dev/null"` to sidestep the problem or you may configure a bit less
secure options for `localhost` in `~/.ssh/config` if you're feeling adventurous.

{% aside(speaker="orange") %}
Don't use unsecure options for something like this...
{% end %}

Yeah, that's probably right. You can but you shouldn't.

#### deploy-rs

Now, we're ready to set up `deploy-rs`. [This
blogpost](https://artemis.sh/2023/06/06/cross-compile-nixos-for-great-good.html) helped me a bit to
set this up so you might get more value from it than from me half regurgitating information from
there and half blind-stumbling around working solutions and bad practices.

{{ flake_and_diff(dir="04_deploy") }}

Here, we've added a few things just to appease `deploy-rs`. It wants to know the filesystems you're
using, it wants some additional GRUB configuration (so we just get rid of it) and it needs your SSH
user to be trusted, otherwise the switch doesn't work because our packages aren't signed with
anything the VM trusts.

I'm not sure what it does with the filesystem knowledge and I don't see why `alice` needs to be
explicitly trusted when she has full sudo powers which I assume she's using, but this is what I've
found to work.

On your machine, you now need to have `deploy-rs` callable, which you can achieve with running `nix shell github:serokell/deploy-rs` if you have working `nix` and flakes enabled.

Once you have that, you can run `deploy '.#obsidian-vm'` and the system should be updated. You can
do some changes like adding a user or installing something to see the changes take effect. You can
for example run `which vim` to make sure it is not installed, then trying again after adding the
following to your modules and deploying:

```nix
({ pkgs, ... }: { environment.systemPackages = [ pkgs.vim ]; })
```

With this we can run a VM and then update that VM without exiting it. So we're not exactly doing
anything we set out to do at the start of the journey, but how much harder can it be to do this
stuff on actual physical machines?

## Conclusion & next steps

{% aside(speaker="orange") %}
Are we really doing conclusions? Is there going to be any useful information there are you just
going to condense stuff into two paragraphs?
{% end %}

Yes, we're doing this, no, there will be no additional information. It just felt weird abruptly
ending the post so I'm doing this.

Running a NixOS system in QEMU is extremely easy to do. Setting up continuous deployments is just a
tiny bit harder, but there's a lot of people doing that already so it's not that hard to figure out.
Now we're ready to update stuff once we have something to update.

My plan going forward is to run the system in QEMU simulating a Raspberry Pi. To date, I have not
seen any post where anyone has done it successfully. That's not to say that I expect to be the first
person to do it, but no one seems to have shared how to.

Then finally, I'll try it out on a real hardware. I mean as I said in the beginning, I already did,
but right now it's just a mess of random options without understanding half of them, so I'll have a
reason to polish them and dig into all of them.
