#!/usr/bin/env bash
# Reviewer check for the v2 branch: with `input_v2_enabled` off, the package
# must behave exactly like `main`. This script makes that mechanically
# checkable against a base branch (default `main`):
#
#   1. files that must be byte-identical to the base;
#   2. v1 layer files that may differ ONLY by inserted gate lines —
#      `input_v2_enabled(rt) && return <name>_v2(...)`, or an
#      `if input_v2_enabled(...) ... end` block (whose body calls into v2) —
#      plus comment lines;
#   3. shared files that may differ by additions only (new inputs, structs,
#      API, message types, includes — never a deleted or changed line);
#   4. shared files whose only non-additive changes are extended keyword
#      lists / type unions and the reactor's lifecycle gates: their deleted
#      lines are printed with their replacements for a by-eye check.
#
# Everything else (`src/v2/**` incl. `src/v2/bridge/`, `src/TomlSyntax/**`) is
# v2-only code reached through those gates, and is free to change.
#
# Usage: scripts/check_v1_parity.sh [base-ref]
set -u
base="${1:-main}"
status=0

identical=(
  src/StaticLint
  src/lint_syntax_rules
  src/SymbolServer
  src/URIs2
  src/utils.jl
  src/compat.jl
  src/exception_types.jl
  src/sourcetext.jl
  src/layer_files.jl
  src/layer_parse_products.jl
  src/layer_inventory.jl
  src/layer_module_tree.jl
  src/layer_visibility.jl
  src/layer_scope_modules.jl
  src/lint_emission.jl
  src/config_common.jl
  src/layer_static_lint.jl
  src/layer_test_setups.jl
  src/layer_completions.jl
  src/layer_actions.jl
  src/layer_formatting.jl
)

gated=(
  src/layer_syntax_trees.jl
  src/layer_projects.jl
  src/layer_environment.jl
  src/layer_includes.jl
  src/layer_file_analysis.jl
  src/layer_testitems.jl
  src/layer_hover.jl
  src/layer_misc.jl
  src/layer_navigation.jl
  src/layer_references.jl
  src/layer_signatures.jl
  src/layer_symbols.jl
)

additive=(
  src/JuliaWorkspaces.jl
  src/packagedef.jl
  # layer_diagnostics.jl is main + its derived_diagnostics gate + the option
  # validation for the v2-only Aqua rules in _validate_lint_rules! (rule
  # registration and config validation are shared; only emission is v2-gated).
  src/layer_diagnostics.jl
  src/inputs.jl
  src/public.jl
  src/lint_rules.jl
  src/precompile.jl
  src/dynamic_feature/dynamic_fsm.jl
  juliadynamicanalysisprocess
  shared
)

eyeball=(
  src/types.jl
  src/fileio.jl
  src/dynamic_feature/dynamic_messages.jl
  src/dynamic_feature/dynamic_feature.jl
)

echo "== 1. byte-identical to $base"
for f in "${identical[@]}"; do
  if ! git diff --quiet "$base" -- "$f"; then
    echo "   DIFFERS: $f"; git diff --stat "$base" -- "$f" | sed 's/^/      /'; status=1
  fi
done

echo "== 2. gate lines only"
for f in "${gated[@]}"; do
  out=$(git diff "$base" -- "$f" | grep -E '^[-+][^-+]' | awk '
    /^-/ { bad = bad $0 "\n"; next }
    depth > 0 {
      if ($0 ~ /^\+[[:space:]]*(if|for|while|let|try|begin|function)([[:space:]]|$)/ || $0 ~ /[[:space:]]do[[:space:]]*$/) depth++
      if ($0 ~ /^\+[[:space:]]*end[[:space:]]*$/) depth--
      next
    }
    /^\+[[:space:]]*#/ { next }
    /^\+[[:space:]]*$/ { next }
    /^\+[[:space:]]*input_v2_enabled\((rt|runtime)\)[[:space:]]*&&[[:space:]]*return[[:space:]]+[A-Za-z_]+_v2\(/ { next }
    /^\+[[:space:]]*if[[:space:]]+input_v2_enabled\((rt|runtime)\)/ { depth = 1; next }
    { bad = bad $0 "\n" }
    END { if (bad != "") printf "%s", bad }')
  if [ -n "$out" ]; then
    echo "   NON-GATE LINES in $f:"; echo "$out" | sed 's/^/      /'; status=1
  fi
done

echo "== 3. additions only"
for f in "${additive[@]}"; do
  if git diff "$base" -- "$f" | grep -qE '^-[^-]'; then
    echo "   DELETIONS in $f:"; git diff "$base" -- "$f" | grep -E '^-[^-]' | sed 's/^/      /'; status=1
  fi
done

echo "== 4. by eye: every deleted line below must reappear extended (a kwarg, a union member, a lifecycle gate)"
for f in "${eyeball[@]}"; do
  hunks=$(git diff -U0 "$base" -- "$f" | awk '/^@@/ {h=$0; next} /^-[^-]/ {if (h != "") {print h; h=""} print} /^\+[^+]/ {if (h == "") print}' )
  if [ -n "$hunks" ]; then echo "   $f:"; echo "$hunks" | sed 's/^/      /'; fi
done

if [ "$status" -eq 0 ]; then echo "OK: flag-off parity holds structurally (section 4 is for the reviewer's eye)"; fi
exit "$status"
