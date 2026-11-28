export PATH="$HOME/.cargo/bin:$HOME/.elan/bin:$PATH"
cd ~/e8
for c in humantime humantime-r4; do for j in 1 2 3; do
  rm -rf "${c:?}/target" "out-${c:?}-j${j:?}"; mkdir -p "out-$c-j$j"
  ( cd $c && /usr/bin/time -f "WALL=%e CPU=%U+%S RSS_KB=%M" cargo mutants --test-tool nextest --no-shuffle --jobs $j -o ../out-$c-j$j ) > out-$c-j$j.log 2>&1
  echo "$c j=$j exit=$? $(grep -E '^WALL=' out-$c-j$j.log) $(grep -E 'mutants tested' out-$c-j$j.log)"
done; done
echo E8_DONE
