local H = require("helpers")
local git = require("diff.git")
local content = require("diff.content")

local function await(fn)
  local result, done = nil, false
  fn(function(...) result = { ... }; done = true end)
  H.wait(function() return done end, "git callback")
  return unpack(result)
end

return {
  { "repo info resolves the git dir, including linked worktrees", function()
    local repo = H.repo({ ["a.txt"] = "a\n" })
    local info = await(function(cb) git.get_repo_info(repo, cb) end)
    H.eq(info.root, repo)
    H.eq(info.git_dir, repo .. "/.git")

    local wt = vim.fn.resolve(vim.fn.tempname())
    H.git(repo, "worktree", "add", "-q", wt)
    info = await(function(cb) git.get_repo_info(wt, cb) end)
    H.eq(info.root, wt)
    H.ok(info.git_dir:match("/%.git/worktrees/"), "worktree git dir: " .. info.git_dir)
  end },

  { "status never rewrites the index", function()
    local repo = H.repo({ ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
    local index = repo .. "/.git/index"
    local before = vim.uv.fs_stat(index).ino
    -- Make the cached stat info stale; plain `git status` would refresh it.
    vim.uv.fs_utime(repo .. "/a.txt", os.time() + 10, os.time() + 10)
    await(function(cb) git.get_status(repo, cb) end)
    H.eq(vim.uv.fs_stat(index).ino, before, "index was rewritten by a read-only command")
  end },

  { "diffstat never rewrites the index either", function()
    local repo = H.repo({ ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
    H.write(repo, "a.txt", "A\n")
    local index = repo .. "/.git/index"
    local before = vim.uv.fs_stat(index).ino
    vim.uv.fs_utime(repo .. "/b.txt", os.time() + 10, os.time() + 10)
    local stats = await(function(cb) git.get_diffstat(repo, cb) end)
    H.eq(vim.uv.fs_stat(index).ino, before, "index was rewritten by get_diffstat")
    H.eq(stats.unstaged["a.txt"], { added = 1, deleted = 1, binary = false })
  end },

  { "file content is exact: blank tail lines, CRLF, missing newline", function()
    local cases = { "a\nb\n\n\n", "a\r\nb\r\n", "a\nb", "" }
    for _, bytes in ipairs(cases) do
      local repo = H.repo({ ["f.txt"] = bytes })
      local from_git = await(function(cb) git.get_file_at_ref(repo, "HEAD", "f.txt", cb) end)
      local from_disk = content.read_worktree(repo .. "/f.txt")
      H.eq(from_git, from_disk, "git and disk disagree for " .. vim.inspect(bytes))
    end
  end },

  { "commit details: files, renames, stats and the root commit", function()
    local repo = H.repo({ ["old.txt"] = "1\n2\n3\n", ["keep.txt"] = "k\n" })
    local root_hash = vim.trim(H.git(repo, "rev-parse", "HEAD"))
    local d = await(function(cb) git.get_commit_details(repo, root_hash, cb) end)
    H.eq(#d.files, 2, "root commit should list its files")
    H.eq(d.body, { "initial" })

    H.git(repo, "mv", "old.txt", "new.txt")
    H.write(repo, "keep.txt", "k\nk2\n")
    H.git(repo, "commit", "-qam", "rename and edit\n\nbody line")
    d = await(function(cb) git.get_commit_details(repo, "HEAD", cb) end)
    H.eq(d.body, { "rename and edit", "", "body line" })
    local by_path = {}
    for _, f in ipairs(d.files) do by_path[f.path] = f end
    H.eq(by_path["new.txt"].status, "renamed")
    H.eq(by_path["new.txt"].old_path, "old.txt")
    H.eq(by_path["keep.txt"].stat, { added = 1, deleted = 0, binary = false })
    H.eq({ d.added, d.deleted }, { 1, 0 })
  end },

  { "patches are applied to the index through stdin", function()
    local repo = H.repo({ ["f.txt"] = "a\nb\n" })
    local patch = "--- a/f.txt\n+++ b/f.txt\n@@ -2,1 +2,1 @@\n-b\n+B\n"
    local ok, err = await(function(cb) git.apply_to_index(repo, patch, false, cb) end)
    H.ok(ok, err)
    H.eq(H.git(repo, "show", ":f.txt"), "a\nB\n")
    ok = await(function(cb) git.apply_to_index(repo, patch, true, cb) end)
    H.ok(ok)
    H.eq(H.git(repo, "show", ":f.txt"), "a\nb\n")
  end },
}
