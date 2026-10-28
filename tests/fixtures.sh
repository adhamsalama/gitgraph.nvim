# Builds the fixture repos the tests use. Sourced by tests/run.sh: setup_fixtures <dir>

setup_fixtures() {
  local dir=$1
  (
    set -e
    cd "$dir"

    # graph: a merge, a tag, an empty subject and an author with shell-hostile characters
    mkdir repo && cd repo && git init -q -b main
    git config user.name 'Test "Quote" $USER'
    for i in 1 2 3; do echo $i > f; git add f; git commit -qm "main $i"; done
    git checkout -qb feature/x
    echo x > g && git add g && git commit -qm 'feat: x with "quotes" and $dollar'
    git commit -q --allow-empty --allow-empty-message -m ''
    git checkout -q main
    echo 4 > f && git commit -qam "main 4"
    git merge -q --no-ff feature/x -m "merge x"
    git tag v1
    cd ..

    # workspace: one of each kind of status entry
    mkdir ws && cd ws && git init -q -b main
    printf 'a\nb\n' > tracked.txt; echo old > renamed-src.txt; echo keep > discard-me.txt
    git add . && git commit -qm "initial"
    git checkout -qb feature && git commit -q --allow-empty -m "feature work" && git checkout -q main
    printf 'a\nB\n' > tracked.txt         # unstaged modification
    echo new > untracked.txt              # untracked
    git mv renamed-src.txt renamed-dst.txt # staged rename
    echo changed > discard-me.txt         # to be discarded
    cd ..

    # empty: no commits yet
    mkdir empty && cd empty && git init -q -b main && echo x > a.txt
    cd ..

    # br: a bare "origin", the clone under test (work) and a second clone (other) that moves origin
    mkdir br && cd br
    git init -q --bare -b main origin.git
    git clone -q origin.git work 2>/dev/null && cd work
    echo 1 > f && git add f && git commit -qm "c1" && git push -q -u origin main 2>/dev/null
    git checkout -qb feature && git commit -q --allow-empty -m "feature 1" && git push -q -u origin feature 2>/dev/null
    git checkout -qb merged-branch main && git checkout -q main
    git checkout -qb unmerged && git commit -q --allow-empty -m "unmerged work" && git checkout -q main
    git tag v1
    cd .. && git clone -q origin.git other 2>/dev/null && cd other
    git checkout -qb remote-only && git commit -q --allow-empty -m ro && git push -q origin remote-only 2>/dev/null
    git checkout -q main && git commit -q --allow-empty -m "upstream moved" && git push -q origin main 2>/dev/null
    cd ../work && git fetch -q && git commit -q --allow-empty -m "local diverged"
    cd ../..

    # rw: history rewriting. base -> side merged in -> c1 c2 (pushed) -> c3 c4 -> c5 c6 (both edit x,
    # so swapping them conflicts). Each cN adds file N.
    git init -q --bare -b main rw-origin.git
    mkdir rw && cd rw && git init -q -b main
    echo base > base && git add base && git commit -qm base
    git checkout -qb side && echo s > s && git add s && git commit -qm side && git checkout -q main
    git merge -q --no-ff side -m "merge side"
    for i in 1 2 3 4; do echo $i > $i && git add $i && git commit -qm "c$i"; done
    git remote add origin ../rw-origin.git && git push -q -u origin HEAD~2:refs/heads/main 2>/dev/null
    git branch -q --set-upstream-to=origin/main
    echo 5 > x && git add x && git commit -qm c5
    echo 6 > x && git commit -qam c6
  )
}
