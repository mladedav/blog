{% import "macros/code_tabs.html" as code_tabs %}
{% set nix_code = load_data(path="assets/nixos/" ~ dir ~ "/flake.nix", format="plain") %}
{% set diff_code = load_data(path="assets/nixos/" ~ dir ~ "/flake.nix.diff", format="plain") %}

{% set body_md = '
```nix
' ~ nix_code ~ '
```

```diff
' ~ diff_code ~ '
```
' %}

<details>
<summary>flake.nix</summary>
{{ code_tabs::render(names=["nix","diff"], body_html=body_md | markdown(inline=true)) }}
</details>
