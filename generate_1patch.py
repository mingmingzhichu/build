#!/usr/bin/env python3
"""Build fixed merged 1.patch from original + exec/reboot fixes.
Usage: python3 generate_1patch.py
Output: ./1.patch
"""
import urllib.request
from pathlib import Path

URL = (
    "https://raw.githubusercontent.com/mingmingzhichu/build/"
    "004e62124f31b78efbc3385c0add926c4bb10805/1.patch"
)
print("Downloading original 1.patch ...")
orig = urllib.request.urlopen(URL, timeout=60).read().decode()

old_exec = """diff --git a/fs/exec.c b/fs/exec.c
index 3cc864bd8310..6df8f27b441e 100644
--- a/fs/exec.c
+++ b/fs/exec.c
@@ -1717,11 +1717,21 @@ static int exec_binprm(struct linux_binprm *bprm)
 /*
  * sys_execve() executes a new program.
  */
+#ifdef CONFIG_KSU_MANUAL_HOOK
+__attribute__((hot))
+extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
+\t\t\t\tvoid *argv, void *envp, int *flags);
+#endif
+
 static int do_execveat_common(int fd, struct filename *filename,
 \t\t\t      struct user_arg_ptr argv,
 \t\t\t      struct user_arg_ptr envp,
 \t\t\t      int flags)
 {
+\t#ifdef CONFIG_KSU_MANUAL_HOOK
+\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
+\t#endif
+
 \tchar *pathbuf = NULL;
 \tstruct linux_binprm bprm;
 \tstruct file *file;
"""

new_exec = """diff --git a/fs/exec.c b/fs/exec.c
index 3cc864bd8310..ksu_exec_fix 100644
--- a/fs/exec.c
+++ b/fs/exec.c
@@ -1717,6 +1717,16 @@ static int exec_binprm(struct linux_binprm *bprm)
 /*
  * sys_execve() executes a new program.
  */
+#ifdef CONFIG_KSU_MANUAL_HOOK
+__attribute__((hot))
+extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
+\t\t\t\tvoid *argv, void *envp, int *flags);
+__attribute__((hot))
+extern int ksu_handle_post_execveat(int *fd, struct filename **filename_ptr,
+\t\t\t\tvoid *argv, void *envp, int *flags,
+\t\t\t\tint *retval);
+#endif
+
 static int do_execveat_common(int fd, struct filename *filename,
 \t\t\t      struct user_arg_ptr argv,
 \t\t\t      struct user_arg_ptr envp,
 \t\t\t      int flags)
 {
 \tchar *pathbuf = NULL;
 \tstruct linux_binprm bprm;
 \tstruct file *file;
 \tstruct files_struct *displaced;
 \tint retval;
+
+#ifdef CONFIG_KSU_MANUAL_HOOK
+\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
+#endif
 
 \tif (IS_ERR(filename))
 \t\treturn PTR_ERR(filename);
@@ -1840,6 +1850,9 @@ static int do_execveat_common(int fd, struct filename *filename,
 \tputname(filename);
 \tif (displaced)
 \t\tput_files_struct(displaced);
+#ifdef CONFIG_KSU_MANUAL_HOOK
+\tksu_handle_post_execveat(&fd, &filename, &argv, &envp, &flags, &retval);
+#endif
 \treturn retval;
 
 out:
@@ -1862,6 +1875,9 @@ static int do_execveat_common(int fd, struct filename *filename,
 \t\treset_files_struct(displaced);
 out_ret:
 \tputname(filename);
+#ifdef CONFIG_KSU_MANUAL_HOOK
+\tksu_handle_post_execveat(&fd, &filename, &argv, &envp, &flags, &retval);
+#endif
 \treturn retval;
 }
 
"""

if old_exec not in orig:
    raise SystemExit("ERROR: expected exec hunk not found in original 1.patch")

text = orig.replace(old_exec, new_exec, 1)
text = text.replace(
    "+#ifdef CONFIG_KSU\n"
    "+extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n"
    "+#endif\n",
    "+#ifdef CONFIG_KSU_MANUAL_HOOK\n"
    "+extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n"
    "+#endif\n",
)
text = text.replace(
    "+#ifdef CONFIG_KSU \n"
    "+\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
    "+#endif\n",
    "+#ifdef CONFIG_KSU_MANUAL_HOOK\n"
    "+\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
    "+#endif\n",
)

out = Path("1.patch")
out.write_text(text)
assert "ksu_handle_post_execveat" in text
print(f"Wrote {out.resolve()} ({len(text)} bytes)")
print("post_execveat count:", text.count("ksu_handle_post_execveat"))
