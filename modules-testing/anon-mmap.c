#define _GNU_SOURCE        /* or _BSD_SOURCE or _SVID_SOURCE */
#include <unistd.h>
#include <sys/syscall.h>   /* For SYS_xxx definitions */
#include <sys/types.h>
#include <sched.h>
#include <sys/mman.h>
#include <signal.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <sys/wait.h>

#define STACK_SIZE 1024*1024*1 //1M

int thread_func(void *lparam) {
    char * str = "this is temp string";
    char * str1 = "this is temp string";
    printf("thread id %d \n", (int)syscall(SYS_gettid));
    printf("thread get param : %d \n", (*(int*)lparam));
    printf("stack address: %p\n", str);
    sleep(30);
    return 0;
}


void child_handler(int sig) {
    printf("I got a SIGCHLD\n");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL,  _IONBF, 0);
    signal(SIGCHLD, child_handler);
    //signal(SIGUSR1, SIG_IGN);

    void *pstack = (void *)mmap(NULL,
                                STACK_SIZE,
                                PROT_READ | PROT_WRITE,
                                MAP_PRIVATE | MAP_ANONYMOUS | MAP_ANON | MAP_GROWSDOWN ,
                                -1,
);
    if (MAP_FAILED != pstack) {
        int ret;
        //printf("stack addr : 0x%X\n", (int)pstack);
        printf("stack addr : %p\n", pstack);
        /*
        CLONE_VM  (0x100) - tells the kernel to let the original process and the clone in the same memory space;
        CLONE_FS (0x200) - both get the same file system information;
        CLONE_FILES (0x400) - share file descriptors;
        CLONE_SIGHAND (0x800) - both processes share the same signal handlers;
        CLONE_THREAD (0x10000) - this tells the kernel, that both processes would belong to the same thread group (be threads within the same process);
        */
        int arg = 1234;
        ret = clone(thread_func,
                    (void *)((unsigned char *)pstack + STACK_SIZE),
                    CLONE_VM | CLONE_FS  | CLONE_FILES | CLONE_SIGHAND |CLONE_THREAD |SIGCHLD,
                    //CLONE_VM | CLONE_FS  | CLONE_FILES | CLONE_SIGHAND |SIGCHLD,
                    (void *)&arg);
        if (-1 != ret)
        {
            printf("PID: %d\n", getpid());
            pid_t pid = 0;
            printf("start thread %d \n", ret);
            sleep(60);
            //pid = waitpid(-1, NULL,  __WCLONE | __WALL);
            printf("child : %d exit %s\n", pid,strerror(errno));
        } else {
            printf("clone failed %s\n", strerror(errno) );
        }

    } else {
        printf("mmap() failed %s\n", strerror(errno));
    }
    return 0;
}
