#!/bin/bash
# Installs the "Export to imarpbundle" BBEdit script and its helper.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

helper_dir="$HOME/Library/Application Support/imarp"
mkdir -p "$helper_dir"
cp "$here/make-imarpbundle.sh" "$helper_dir/make-imarpbundle.sh"
chmod +x "$helper_dir/make-imarpbundle.sh"

scripts_dir="$HOME/Library/Application Support/BBEdit/Scripts"
mkdir -p "$scripts_dir"
osacompile -o "$scripts_dir/Export to imarpbundle.scpt" "$here/Export to imarpbundle.applescript"

echo "Installed. In BBEdit, open the .md/.marp deck you want to export,"
echo "then choose Scripts > Export to imarpbundle."
