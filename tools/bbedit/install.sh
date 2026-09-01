#!/bin/bash
# Installs the "Export to marpbundle" BBEdit script and its helper.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

helper_dir="$HOME/Library/Application Support/imarp"
mkdir -p "$helper_dir"
cp "$here/make-marpbundle.sh" "$helper_dir/make-marpbundle.sh"
chmod +x "$helper_dir/make-marpbundle.sh"

scripts_dir="$HOME/Library/Application Support/BBEdit/Scripts"
mkdir -p "$scripts_dir"
rm -f "$scripts_dir/Export to imarpbundle.scpt"
osacompile -o "$scripts_dir/Export to marpbundle.scpt" "$here/Export to marpbundle.applescript"
rm -f "$helper_dir/make-imarpbundle.sh"

echo "Installed. In BBEdit, open the .md/.marp deck you want to export,"
echo "then choose Scripts > Export to marpbundle."
