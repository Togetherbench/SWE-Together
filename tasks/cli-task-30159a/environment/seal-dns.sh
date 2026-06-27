#!/bin/sh
# Runtime DNS sinkhole — appended via BASH_ENV/ENV at every shell.
# Idempotent via /tmp/.seal-dns-applied marker.
if [ ! -f /tmp/.seal-dns-applied ]; then
  _entries='127.0.0.1 github.com api.github.com codeload.github.com docs.github.com gist.github.com support.github.com skills.github.com github.blog githubusercontent.com raw.githubusercontent.com patch-diff.githubusercontent.com gist.githubusercontent.com camo.githubusercontent.com avatars.githubusercontent.com github.githubassets.com desktop.github.com gitlab.com bitbucket.org huggingface.co hf.co cdn-lfs.huggingface.co discuss.huggingface.co cdn-avatars.huggingface.co'
  if [ -w /etc/hosts ] 2>/dev/null; then
    echo "$_entries" >> /etc/hosts 2>/dev/null
  elif command -v sudo >/dev/null 2>&1; then
    sudo sh -c "echo '$_entries' >> /etc/hosts" 2>/dev/null
  fi
  touch /tmp/.seal-dns-applied 2>/dev/null
fi
