# Read one JSON record per line: malformed/incomplete trailing records are ignored.
reduce inputs as $line ("";
  (try ($line | fromjson) catch null) as $row
  | if ($row | type) == "object" and $row.type == "user" and $row.isMeta != true then
      ($row.message.content
       | if type == "string" then . elif type == "array" then
           [ .[] | select(.type == "text") | .text | select(type == "string") ] | join(" ")
         else "" end
       | sub("^\\s+"; "")) as $text
      | if $text != "" and (any($prefixes[0][]; . as $prefix | $text | startswith($prefix)) | not)
        then $text else . end
    else . end)
