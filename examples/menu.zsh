# quickmenu menu definitions
#
#   qm_item [-g group] [-d description] [-c condition] [-e] [-y] <label> <command>
#
#     -g  group name shown before the label
#     -d  extra text used for fuzzy matching
#     -c  only show the item when this command succeeds
#     -e  put the command on the prompt instead of running it
#     -y  ask for confirmation first
#
# Placeholders are filled in when the item is chosen:
#
#   {{prompt:Label}}                 ask for text
#   {{prompt:Label=default}}         ask, with a default
#   {{pick:ls *.log}}                pick one line of the command's output
#   {{file:*.xcodeproj *.xcworkspace}}  pick a matching file/dir in $PWD
#   {{dir}}                          pick a sub-directory
#   {{env:HOME}}                     expand an environment variable
#
# Values are shell-quoted. Append "!" ({{prompt!:Flags}}) to insert raw text.

# --- open things -------------------------------------------------------------

qm_item -g open  'Launch Code'          'code .'
qm_item -g open  'Launch Finder'        'open .'
qm_item -g open  'Launch Xcode project' 'open {{file:*.xcodeproj *.xcworkspace}}' \
        -d 'xcode ios swift'
qm_item -g open  'Open in browser'      'open {{prompt:URL=http://localhost:3000}}'
qm_item -g open  'Open current repo on GitHub' 'gh repo view --web' \
        -c 'git rev-parse --is-inside-work-tree'

# --- git ---------------------------------------------------------------------

qm_git_item -g git 'Commit everything'  'git add -A && git commit -m {{prompt:Message=Automated commit}}'
qm_git_item -g git 'Status'             'git status -sb'
qm_git_item -g git 'Pull (rebase)'      'git pull --rebase'
qm_git_item -g git 'Push current branch' 'git push -u origin HEAD'
qm_git_item -g git 'Log (graph)'        'git --no-pager log --oneline --graph --decorate -20'
qm_git_item -g git 'Switch branch'      'git switch {{pick:git branch --format="%(refname:short)"}}'
qm_git_item -g git 'New branch'         'git switch -c {{prompt:Branch name}}'
qm_git_item -g git 'Discard all changes' -y 'git reset --hard && git clean -fd'
qm_git_item -g git 'Create pull request' 'gh pr create --fill --web'

# --- dev ---------------------------------------------------------------------

qm_item -g dev 'npm install'  'npm install'  -c '[[ -f package.json ]]'
qm_item -g dev 'npm run ...'  'npm run {{pick:node -e "console.log(Object.keys(require(\"./package.json\").scripts||{}).join(\"\\n\"))"}}' \
        -c '[[ -f package.json ]]'
qm_item -g dev 'Run tests'    'npm test'     -c '[[ -f package.json ]]'
qm_item -g dev 'Python venv'  'python3 -m venv .venv && source .venv/bin/activate'

# --- shell -------------------------------------------------------------------

qm_item -g shell 'Jump to directory' 'cd {{dir}}'
qm_item -g shell 'Disk usage here'   'du -sh * | sort -h | tail -20'
qm_item -g shell 'Reload zsh'        'exec zsh'
qm_item -g shell 'Edit this menu'    'qm --edit'
qm_item -g shell 'Kill port'         'lsof -ti tcp:{{prompt:Port=3000}} | xargs kill -9' -y
