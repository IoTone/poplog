/* Spike S3 (PORTING-X86-64-WINDOWS.md section 9).
 *
 * Can a Cygwin executable sit at a fixed base below 2 GB, use 32-bit
 * absolute addresses, hold a fixed read-write-execute reserve for the Pop
 * heap, map a file at a fixed address, and still fork?
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/time.h>

extern long cell;
extern long abs_imm(void);
extern long abs_load(void);
extern long abs_jmp(void);

#define HEAP_BASE   ((char *) 0x20000000UL)
#define HEAP_SIZE   (512UL << 20)
#define IMG_ADDR    ((char *) 0x18000000UL)

static int fails;
static void check(const char *what, int ok) {
    printf("  %-52s %s\n", what, ok ? "OK" : "FAIL");
    if (!ok) fails++;
    fflush(stdout);
}

static double now(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

int main(int argc, char **argv) {
    unsigned long touch_mb = argc > 1 ? strtoul(argv[1], NULL, 0) : 64;
    static const unsigned char ret42[] = { 0xb8, 42, 0, 0, 0, 0xc3 }; /* mov $42,%eax; ret */

    printf("layout\n");
    printf("  main=%p  &cell=%p  sbrk(0)=%p  stack~%p  pagesize=%d\n",
           (void *) main, (void *) &cell, sbrk(0), (void *) &argc, getpagesize());
    check("image below 2 GB", (unsigned long) main < 0x80000000UL
                              && (unsigned long) &cell < 0x80000000UL);
    check("movq $sym, %reg", abs_imm() == (long) &cell);
    check("movq sym, %reg", abs_load() == 0x1122334455667788L);
    check("jmp to absolute code address", abs_jmp() == (long) &cell);

    printf("heap reserve at %p, %lu MB\n", (void *) HEAP_BASE, HEAP_SIZE >> 20);
    char *heap = mmap(HEAP_BASE, HEAP_SIZE, PROT_READ | PROT_WRITE | PROT_EXEC,
                      MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED | MAP_NORESERVE, -1, 0);
    if (heap == MAP_FAILED) printf("  mmap: %s\n", strerror(errno));
    check("mmap MAP_FIXED rwx at requested address", heap == HEAP_BASE);
    if (heap != HEAP_BASE) return 1;

    memcpy(heap, ret42, sizeof ret42);
    check("code written into the reserve runs", ((int (*)(void)) heap)() == 42);

    unsigned long i;
    for (i = 1; i < touch_mb; i++) heap[i << 20] = (char) i;
    char *last = heap + HEAP_SIZE - 65536;
    strcpy(last, "top of reserve");
    check("last page of the reserve is usable", !strcmp(last, "top of reserve"));

    check("mprotect to read-only and back",
          mprotect(heap + (8UL << 20), 65536, PROT_READ) == 0
          && mprotect(heap + (8UL << 20), 65536, PROT_READ | PROT_WRITE | PROT_EXEC) == 0);

    printf("saved-image style file mapping at %p\n", (void *) IMG_ADDR);
    char path[] = "s3_image.tmp";
    /* Cygwin refuses PROT_EXEC on a file without execute permission (EACCES),
       so the image file is created 0700; the 0600 case is shown below. */
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0700);
    char *buf = calloc(1, 3 * 65536);
    strcpy(buf + 65536, "second 64K block");
    write(fd, buf, 3 * 65536);
    char *img = mmap(IMG_ADDR, 65536, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_FIXED, fd, 65536);
    if (img == MAP_FAILED) printf("  mmap: %s\n", strerror(errno));
    check("file mapped MAP_FIXED at a 64 KB offset", img == IMG_ADDR
          && !strcmp(img, "second 64K block"));
    char *bad = mmap(IMG_ADDR + (16UL << 20), 4096, PROT_READ,
                     MAP_PRIVATE | MAP_FIXED, fd, 4096);
    printf("  file offset 4096 (not a 64 KB multiple): %s\n",
           bad == MAP_FAILED ? strerror(errno) : "accepted");
    bad = mmap(IMG_ADDR + (32UL << 20) + 4096, 4096, PROT_READ | PROT_WRITE,
               MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    printf("  address not a 64 KB multiple: %s\n",
           bad == MAP_FAILED ? strerror(errno) : "accepted");

    int fd2 = open("s3_noexec.tmp", O_RDWR | O_CREAT | O_TRUNC, 0600);
    write(fd2, buf, 3 * 65536);
    bad = mmap(IMG_ADDR + (48UL << 20), 65536, PROT_READ | PROT_WRITE | PROT_EXEC,
               MAP_PRIVATE | MAP_FIXED, fd2, 0);
    printf("  rwx mapping of a file with mode 0600: %s\n",
           bad == MAP_FAILED ? strerror(errno) : "accepted");
    bad = mmap(IMG_ADDR + (64UL << 20), 65536, PROT_READ | PROT_WRITE,
               MAP_PRIVATE | MAP_FIXED, fd2, 0);
    printf("  rw mapping of the same file, then mprotect +x: %s\n",
           bad == MAP_FAILED ? strerror(errno)
           : mprotect(bad, 65536, PROT_READ | PROT_WRITE | PROT_EXEC) ? strerror(errno) : "accepted");
    close(fd2);
    unlink("s3_noexec.tmp");

    printf("fork with %lu MB of the reserve touched\n", touch_mb);
    fflush(stdout);
    double t0 = now();
    pid_t pid = fork();
    if (pid < 0) { printf("  fork: %s\n", strerror(errno)); return 1; }
    if (pid == 0) {
        int ok = ((int (*)(void)) heap)() == 42
                 && !strcmp(last, "top of reserve")
                 && heap[(touch_mb - 1) << 20] == (char) (touch_mb - 1)
                 && (img == IMG_ADDR ? !strcmp(img, "second 64K block") : 1)
                 && abs_load() == 0x1122334455667788L;
        heap[1 << 20] = 99;                 /* must not reach the parent */
        _exit(ok ? 0 : 3);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    double dt = now() - t0;
    check("child sees the reserve, the mapping and the image", WIFEXITED(st) && WEXITSTATUS(st) == 0);
    check("child's write did not reach the parent", heap[1 << 20] == 1);
    printf("  fork + child exit + wait: %.0f ms\n", dt * 1000);

    unlink(path);
    printf("s3: %s\n", fails ? "FAILURES" : "ALL OK");
    return fails ? 1 : 0;
}
