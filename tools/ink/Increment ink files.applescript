-- Adds 1 to the number at the start of each file selected in Finder:
-- 9.drawing becomes 10.drawing, and 9.slide.drawing becomes 10.slide.drawing.
-- For a deck's ink files, after inserting a slide: select the files from the
-- new slide's position up, then run this. Ink numbers start at 0: slide 10's
-- ink is number 9.
--
-- Files are renamed highest number first. If a new name would land on a file
-- that isn't selected, nothing is renamed at all.
--
-- For testing, file paths can be given on the command line instead:
-- osascript "Increment ink files.applescript" <file> <file> ...

on run argv
	if (count of argv) > 0 then return incrementFiles(argv)
	tell application "Finder" to set theSelection to selection as alias list
	if (count of theSelection) is 0 then
		display alert "Select the ink files in Finder first."
		return
	end if
	set thePaths to {}
	repeat with theItem in theSelection
		set end of thePaths to POSIX path of theItem
	end repeat
	set theResult to incrementFiles(thePaths)
	if theResult starts with "CONFLICT:" then
		display alert "Nothing was renamed." message (text 10 thru -1 of theResult) & " already exists and isn't selected. Select it too, or choose different files."
	else
		display dialog theResult & " file(s) renamed." buttons {"OK"} default button "OK"
	end if
end run

on incrementFiles(thePaths)
	set script_ to "next_name() { b=${1##*/}; n=${b%%[!0-9]*}; [ -n \"$n\" ] && echo \"${1%/*}/$((10#$n + 1))${b#$n}\"; }
for p in \"$@\"; do
  [ -f \"$p\" ] || continue
  t=$(next_name \"$p\") || continue
  if [ -e \"$t\" ]; then
    selected=0
    for q in \"$@\"; do [ \"$q\" = \"$t\" ] && selected=1; done
    if [ $selected = 0 ]; then echo \"CONFLICT:${t##*/}\"; exit 0; fi
  fi
done
for p in \"$@\"; do
  [ -f \"$p\" ] || continue
  b=${p##*/}; n=${b%%[!0-9]*}
  [ -n \"$n\" ] && printf '%s\\t%s\\n' \"$((10#$n))\" \"$p\"
done | sort -rn | cut -f2- | while IFS= read -r p; do
  mv -n \"$p\" \"$(next_name \"$p\")\" && echo \"$p\"
done | wc -l | tr -d ' '"
	set theArguments to ""
	repeat with thePath in thePaths
		set theArguments to theArguments & " " & quoted form of (thePath as text)
	end repeat
	return do shell script "/bin/bash -c " & quoted form of script_ & " incrementFiles" & theArguments
end incrementFiles
