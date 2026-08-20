#include <limits.h>
#include <libgen.h>
#include <stdio.h>
#include <unistd.h>
#include <mach-o/dyld.h>

int main(int argc, char *argv[]) {
    char exec_path[PATH_MAX];
    uint32_t size = sizeof(exec_path);
    if (_NSGetExecutablePath(exec_path, &size) != 0) return 1;
    char script[PATH_MAX];
    snprintf(script, sizeof(script), "%s/../Resources/runner.sh", dirname(exec_path));
    char *child[argc + 1];
    child[0] = script;
    for (int i = 1; i < argc; i++) child[i] = argv[i];
    child[argc] = NULL;
    execv(script, child);
    perror("execv");
    return 1;
}
