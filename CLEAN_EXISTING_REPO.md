# Cleaning the previously rejected Git history

GitHub already rejected the earlier push because large binaries exist in the local
commit history. Adding `.gitignore` does not remove those old Git objects.

If this repository has **not successfully been published yet** (the usual case after
GH001 rejected the initial push), the simplest clean reset is to make a new root
commit from the source-only tree:

```bash
# Run from the repository root after replacing its files with this package.
git checkout --orphan clean-main
git rm -rf --cached . 2>/dev/null || true
git add .
git commit -m "Initial HOTR Batocera installer"
git branch -M main
git push -u origin main --force
```

Before `git add .`, verify the large files are ignored/untracked:

```bash
git status --short
git check-ignore -v \
  payload/emulators/duckstation/duckstation-qt \
  payload/emulators/pcsx2/pcsx2-lightgun-qt \
  payload/hotr/Hook_of_the_Reaper-x86_64.AppImage \
  dist/HOTR-Batocera43-x86_64.zip
```

If the remote already contains history you need to preserve, do not use the orphan
method. Use `git filter-repo` to remove the large paths from all commits instead.
