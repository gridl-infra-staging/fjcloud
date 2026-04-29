def walk_specs(s):
  (s.specs // [])[],
  ((s.suites // [])[] | walk_specs(.));

[ (.suites // [])[] | walk_specs(.) ] as $all |
{
  passed: ([ $all[] | .tests[]? | .results[]? | select(.status == "passed") ] | length),
  failed: ([ $all[] | .tests[]? | .results[]? | select(.status == "failed") ] | length),
  skipped: ([ $all[] | .tests[]? | .results[]? | select(.status == "skipped") ] | length),
  timedOut: ([ $all[] | .tests[]? | .results[]? | select(.status == "timedOut") ] | length),
  interrupted: ([ $all[] | .tests[]? | .results[]? | select(.status == "interrupted") ] | length),
  specs: [
    $all[] | select(.file? and ((.tests // []) | length) > 0) |
    {
      file,
      title,
      status: ([ .tests[]? | .results[]?.status ] | unique | if length == 1 then .[0] else join(",") end)
    }
  ]
}
