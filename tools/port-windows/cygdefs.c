/* cygdefs.c -- print every libc constant, type size and struct layout that
 * the Pop sources hard-code per operating system, as Cygwin defines them.
 *
 * The CYGWIN clauses in pop/src/unixdefs.ph, unix_tty.ph, unix_select.ph,
 * pop/lib/include/sigdefs.ph and unix_errno.ph are written from this
 * program's output and from nothing else (PORTING-X86-64-WINDOWS.md 3.6):
 * a wrong value there does not fail to build, it fails at run time.
 *
 *      gcc -o cygdefs tools/port-windows/cygdefs.c && ./cygdefs
 *
 * Re-run it after a Cygwin upgrade and diff against cygdefs.out.
 */
#include <stdio.h>
#include <stddef.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/times.h>
#include <sys/resource.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <dirent.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <termios.h>
#include <unistd.h>
#include <utime.h>
#include <time.h>
#include <pwd.h>
#include <dlfcn.h>
#include <ucontext.h>

#define SEC(s)      printf("\n[%s]\n", s)
#define D(x)        printf("%-18s %ld\n", #x, (long) (x))
#define H(x)        printf("%-18s 0x%lx\n", #x, (unsigned long) (x))
#define O(x)        printf("%-18s 0%lo\n", #x, (unsigned long) (x))
#define SZ(t)       printf("%-18s size %2zu %s\n", #t, sizeof(t), ((t) -1 < (t) 0) ? "signed" : "unsigned")
#define ST(t)       printf("struct %-11s size %zu\n", #t, sizeof(struct t))
#define F(t, f)     printf("  %-16s offset %3zu size %2zu\n", #f, offsetof(struct t, f), sizeof(((struct t *) 0)->f))

int main(void) {
    SEC("basic C types");
    printf("char %zu short %zu int %zu long %zu long long %zu pointer %zu float %zu double %zu\n",
           sizeof(char), sizeof(short), sizeof(int), sizeof(long), sizeof(long long),
           sizeof(void *), sizeof(float), sizeof(double));

    SEC("sys/types.h");
    SZ(off_t); SZ(blkcnt_t); SZ(blksize_t); SZ(dev_t); SZ(ino_t); SZ(mode_t);
    SZ(nlink_t); SZ(time_t); SZ(uid_t); SZ(gid_t); SZ(pid_t); SZ(clock_t);
    SZ(size_t); SZ(ssize_t); SZ(suseconds_t); SZ(socklen_t);

    SEC("struct stat");
    ST(stat);
    F(stat, st_dev); F(stat, st_ino); F(stat, st_mode); F(stat, st_nlink);
    F(stat, st_uid); F(stat, st_gid); F(stat, st_rdev); F(stat, st_size);
    F(stat, st_atim); F(stat, st_mtim); F(stat, st_ctim);
    F(stat, st_blksize); F(stat, st_blocks); F(stat, st_birthtim);
    O(S_IFMT); O(S_IFREG); O(S_IFDIR); O(S_IFIFO); O(S_IFLNK);
    ST(timespec); F(timespec, tv_sec); F(timespec, tv_nsec);
    ST(utimbuf); F(utimbuf, actime); F(utimbuf, modtime);

    SEC("struct dirent");
    ST(dirent);
    F(dirent, d_ino); F(dirent, d_type); F(dirent, d_name);
#ifdef __CYGWIN__
    F(dirent, __d_version); F(dirent, __d_internal1);
#endif

    SEC("ioctl");
    H(FIONREAD); H(FIONBIO);
#ifdef FIOCLEX
    H(FIOCLEX);
#else
    printf("FIOCLEX            (not defined)\n");
#endif
#ifdef FIOASYNC
    H(FIOASYNC);
#else
    printf("FIOASYNC           (not defined)\n");
#endif
#ifdef FIOSETOWN
    H(FIOSETOWN);
#else
    printf("FIOSETOWN          (not defined)\n");
#endif
    H(TIOCGWINSZ); H(TIOCSWINSZ);
#ifdef TIOCGPGRP
    H(TIOCGPGRP); H(TIOCSPGRP);
#endif
#ifdef TIOCLINUX
    H(TIOCLINUX);
#endif
    ST(winsize); F(winsize, ws_row); F(winsize, ws_col); F(winsize, ws_xpixel); F(winsize, ws_ypixel);

    SEC("fcntl");
    D(F_DUPFD); D(F_GETFD); D(F_SETFD); D(F_GETFL); D(F_SETFL);
    D(F_GETOWN); D(F_SETOWN); D(F_GETLK); D(F_SETLK); D(F_SETLKW); D(FD_CLOEXEC);
    H(O_RDONLY); H(O_WRONLY); H(O_RDWR); H(O_ACCMODE);
    H(O_NDELAY); H(O_NONBLOCK); H(O_APPEND); H(O_CREAT); H(O_TRUNC); H(O_EXCL);
    H(O_NOCTTY); H(O_SYNC);
#ifdef O_BINARY
    H(O_BINARY); H(O_TEXT);
#endif
    D(R_OK); D(W_OK); D(X_OK); D(F_OK);
    D(SEEK_SET); D(SEEK_CUR); D(SEEK_END);

    SEC("times and timers");
    ST(tms); F(tms, tms_utime); F(tms, tms_stime); F(tms, tms_cutime); F(tms, tms_cstime);
    ST(timeval); F(timeval, tv_sec); F(timeval, tv_usec);
    ST(timezone); F(timezone, tz_minuteswest); F(timezone, tz_dsttime);
    ST(itimerval); F(itimerval, it_interval); F(itimerval, it_value);
    D(ITIMER_REAL); D(ITIMER_VIRTUAL); D(ITIMER_PROF);
    D(_SC_CLK_TCK); D(_SC_PAGESIZE); D(_SC_OPEN_MAX); D(_SC_NPROCESSORS_ONLN);
    ST(tm); F(tm, tm_sec); F(tm, tm_min); F(tm, tm_hour); F(tm, tm_mday); F(tm, tm_mon);
    F(tm, tm_year); F(tm, tm_wday); F(tm, tm_yday); F(tm, tm_isdst); F(tm, tm_gmtoff); F(tm, tm_zone);

    SEC("resources");
    D(RLIMIT_CPU); D(RLIMIT_FSIZE); D(RLIMIT_DATA); D(RLIMIT_STACK); D(RLIMIT_CORE);
    D(RLIMIT_NOFILE); D(RLIMIT_AS);
    H(RLIM_INFINITY);
    ST(rlimit); F(rlimit, rlim_cur); F(rlimit, rlim_max);

    SEC("mmap");
    H(PROT_NONE); H(PROT_READ); H(PROT_WRITE); H(PROT_EXEC);
    H(MAP_SHARED); H(MAP_PRIVATE); H(MAP_FIXED); H(MAP_ANONYMOUS); H(MAP_NORESERVE);
    H((unsigned long) MAP_FAILED);

    SEC("wait");
    D(WNOHANG); D(WUNTRACED);
#ifdef WCONTINUED
    D(WCONTINUED);
#endif
    printf("status encoding: exit(3) -> 0x%x, low 7 bits = signal\n", 3 << 8);

    SEC("select");
    D(FD_SETSIZE); SZ(fd_mask); printf("sizeof(fd_set)     %zu\n", sizeof(fd_set));
    D(NFDBITS);

    SEC("signals");
    D(SIGHUP); D(SIGINT); D(SIGQUIT); D(SIGILL); D(SIGTRAP); D(SIGABRT);
#ifdef SIGIOT
    D(SIGIOT);
#endif
    D(SIGEMT); D(SIGFPE); D(SIGKILL); D(SIGBUS); D(SIGSEGV); D(SIGSYS); D(SIGPIPE);
    D(SIGALRM); D(SIGTERM); D(SIGURG); D(SIGSTOP); D(SIGTSTP); D(SIGCONT); D(SIGCHLD);
    D(SIGTTIN); D(SIGTTOU); D(SIGIO); D(SIGPOLL); D(SIGXCPU); D(SIGXFSZ); D(SIGVTALRM);
    D(SIGPROF); D(SIGWINCH);
#ifdef SIGLOST
    D(SIGLOST);
#endif
#ifdef SIGPWR
    D(SIGPWR);
#endif
#ifdef SIGINFO
    D(SIGINFO);
#endif
    D(SIGUSR1); D(SIGUSR2); D(NSIG);
#ifdef SIGRTMIN
    D(SIGRTMIN); D(SIGRTMAX);
#endif
    D(SIG_BLOCK); D(SIG_UNBLOCK); D(SIG_SETMASK);
    H(SA_NOCLDSTOP); H(SA_SIGINFO); H(SA_RESTART); H(SA_NODEFER); H(SA_RESETHAND); H(SA_ONSTACK);
    printf("sizeof(sigset_t)   %zu\n", sizeof(sigset_t));
    ST(sigaction); F(sigaction, sa_handler); F(sigaction, sa_mask); F(sigaction, sa_flags);
    printf("struct siginfo     size %zu\n", sizeof(siginfo_t));
    printf("  si_signo         offset %3zu\n  si_code          offset %3zu\n  si_addr          offset %3zu\n",
           offsetof(siginfo_t, si_signo), offsetof(siginfo_t, si_code), offsetof(siginfo_t, si_addr));
    D(FPE_INTDIV); D(FPE_INTOVF); D(FPE_FLTDIV); D(FPE_FLTOVF); D(FPE_FLTUND);
    D(FPE_FLTRES); D(FPE_FLTINV); D(FPE_FLTSUB);
    D(SEGV_MAPERR); D(SEGV_ACCERR); D(BUS_ADRALN); D(BUS_ADRERR); D(BUS_OBJERR);
    D(ILL_ILLOPC); D(ILL_PRVOPC);
    printf("sizeof(ucontext_t) %zu, uc_mcontext offset %zu, rip offset in mcontext %zu\n",
           sizeof(ucontext_t), offsetof(ucontext_t, uc_mcontext), offsetof(mcontext_t, rip));

    SEC("errno");
    D(EPERM); D(ENOENT); D(ESRCH); D(EINTR); D(EIO); D(ENXIO); D(E2BIG); D(ENOEXEC);
    D(EBADF); D(ECHILD); D(EAGAIN); D(ENOMEM); D(EACCES); D(EFAULT); D(EBUSY); D(EEXIST);
    D(EXDEV); D(ENODEV); D(ENOTDIR); D(EISDIR); D(EINVAL); D(ENFILE); D(EMFILE);
    D(ENOTTY); D(EFBIG); D(ENOSPC); D(ESPIPE); D(EROFS); D(EMLINK); D(EPIPE); D(EDOM); D(ERANGE);
    D(EWOULDBLOCK); D(ENOSR); D(ELOOP); D(EDQUOT); D(ENOTSOCK); D(EADDRINUSE);
    D(EISCONN); D(ENOTCONN); D(ECONNREFUSED); D(EALREADY); D(EINPROGRESS);
    D(ENAMETOOLONG); D(ENOTEMPTY); D(ECONNRESET); D(ETIMEDOUT); D(ENOSYS); D(EDEADLK);
    D(EHOSTUNREACH); D(ENETUNREACH); D(EADDRNOTAVAIL); D(EAFNOSUPPORT); D(EPROTONOSUPPORT);
    D(EMSGSIZE); D(ENOBUFS); D(EOPNOTSUPP); D(ECONNABORTED); D(EDESTADDRREQ); D(ESHUTDOWN);

    SEC("termios");
    ST(termios); SZ(tcflag_t); SZ(speed_t); SZ(cc_t); D(NCCS);
    F(termios, c_iflag); F(termios, c_oflag); F(termios, c_cflag); F(termios, c_lflag);
    F(termios, c_line); F(termios, c_cc); F(termios, c_ispeed); F(termios, c_ospeed);
    D(TCSANOW); D(TCSADRAIN); D(TCSAFLUSH); D(TCIFLUSH); D(TCOFLUSH); D(TCIOFLUSH);
    D(_POSIX_VDISABLE);
    D(VINTR); D(VQUIT); D(VERASE); D(VKILL); D(VEOF); D(VEOL); D(VEOL2); D(VMIN); D(VTIME);
    D(VSTART); D(VSTOP); D(VSUSP); D(VREPRINT); D(VDISCARD); D(VWERASE); D(VLNEXT);
#ifdef VSWTC
    D(VSWTC);
#endif
#ifdef VDSUSP
    D(VDSUSP);
#endif
    H(IGNBRK); H(BRKINT); H(IGNPAR); H(PARMRK); H(INPCK); H(ISTRIP); H(INLCR); H(IGNCR);
    H(ICRNL); H(IUCLC); H(IXON); H(IXANY); H(IXOFF); H(IMAXBEL);
    H(OPOST); H(OLCUC); H(ONLCR); H(OCRNL); H(ONOCR); H(ONLRET); H(OFILL); H(OFDEL);
    H(NLDLY); H(NL0); H(NL1); H(CRDLY); H(CR0); H(CR1); H(CR2); H(CR3);
    H(TABDLY); H(TAB0); H(TAB1); H(TAB2); H(TAB3); H(BSDLY); H(BS0); H(BS1);
    H(VTDLY); H(VT0); H(VT1); H(FFDLY); H(FF0); H(FF1);
    H(CBAUD); H(B0); H(B50); H(B75); H(B110); H(B134); H(B150); H(B200); H(B300); H(B600);
    H(B1200); H(B1800); H(B2400); H(B4800); H(B9600); H(B19200); H(B38400);
#ifdef EXTA
    H(EXTA); H(EXTB);
#endif
    H(CBAUDEX); H(B57600); H(B115200); H(B230400); H(B460800);
    H(CSIZE); H(CS5); H(CS6); H(CS7); H(CS8); H(CSTOPB); H(CREAD); H(PARENB); H(PARODD);
    H(HUPCL); H(CLOCAL); H(CRTSCTS);
#ifdef XCASE
    H(XCASE);
#else
    printf("XCASE              (not defined)\n");
#endif
    H(ISIG); H(ICANON); H(ECHO); H(ECHOE); H(ECHOK); H(ECHONL); H(NOFLSH);
    H(TOSTOP); H(IEXTEN); H(FLUSHO); H(ECHOKE); H(ECHOCTL);
#ifdef ECHOPRT
    H(ECHOPRT);
#endif

    SEC("dynamic loading");
    H(RTLD_LAZY); H(RTLD_NOW); H(RTLD_GLOBAL); H(RTLD_LOCAL);

    SEC("passwd, utsname");
    ST(passwd); F(passwd, pw_name); F(passwd, pw_passwd); F(passwd, pw_uid); F(passwd, pw_gid);
    F(passwd, pw_gecos); F(passwd, pw_dir); F(passwd, pw_shell);
    ST(utsname); F(utsname, sysname); F(utsname, nodename); F(utsname, release);
    F(utsname, version); F(utsname, machine);

    SEC("sockets");
    D(AF_UNIX); D(AF_INET); D(AF_INET6); D(SOCK_STREAM); D(SOCK_DGRAM);
    H(SOL_SOCKET); H(SO_REUSEADDR); H(SO_KEEPALIVE); H(SO_BROADCAST); H(SO_LINGER);
    H(SO_SNDBUF); H(SO_RCVBUF); H(SO_ERROR); H(SO_TYPE); H(SO_OOBINLINE);
    H(MSG_OOB); H(MSG_PEEK); D(IPPROTO_TCP); H(TCP_NODELAY);
    ST(sockaddr); F(sockaddr, sa_family); F(sockaddr, sa_data);
    ST(sockaddr_in); F(sockaddr_in, sin_family); F(sockaddr_in, sin_port); F(sockaddr_in, sin_addr);
    return 0;
}
