-- Packages the frontmost BBEdit document into a .marpbundle, using
-- make-marpbundle.sh (installed alongside this script by install.sh).
-- Install with tools/bbedit/install.sh; it then appears in BBEdit's
-- Scripts menu as "Export to marpbundle".

tell application "BBEdit"
	if (count of documents) is 0 then
		display alert "No document is open in BBEdit." message "Open the .md or .marp deck you want to export first."
		return
	end if
	save front document
	set docFile to file of front document
	set docName to name of front document
end tell

set docPOSIX to POSIX path of (docFile as text)
set helperPath to (POSIX path of (path to home folder)) & "Library/Application Support/imarp/make-marpbundle.sh"

try
	set bundlePath to do shell script quoted form of helperPath & " " & quoted form of docPOSIX
on error errMsg
	display alert "Export failed" message errMsg as critical
	return
end try

tell application "Finder"
	activate
	-- "as alias" isn't redundant here: having referenced BBEdit's
	-- dictionary earlier in this script leaves "POSIX file" ambiguous by
	-- the time this runs, and Finder fails to resolve it (-1728) without
	-- an explicit coercion.
	reveal (POSIX file bundlePath as alias)
end tell

display notification ("Exported " & docName) with title "imarp" subtitle "Saved as .marpbundle"
