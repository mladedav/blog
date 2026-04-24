{% set syntax = syntax | default(value="text") %}
{% set code = load_data(path=path, format="plain") %}

```{{ syntax }}
{{ code | safe }}
```
