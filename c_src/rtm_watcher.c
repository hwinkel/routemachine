#include <sys/types.h>
#include <sys/select.h>
#include <sys/socket.h>

#include <netinet/in.h>
#include <arpa/inet.h>

#include <linux/netlink.h>
#include <linux/rtnetlink.h>

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "routemachine.h"

/* Keep these in sync with the erlang side. */
#define RTM_CMD_ROUTE_ADD   0
#define RTM_CMD_ROUTE_DEL   1
#define RTM_CMD_ROUTE_ERR 255

enum response_data {
    CMD,
    MASK,
    DST,
    GW,
    PRIO,
    NUM_RESP
};

#define BUFSIZE 8192

void
parse_attrs(struct rtattr *attrs[], struct rtattr *rta, int len)
{
    memset(attrs, 0, sizeof(*rta) * (RTA_MAX + 1));
    while (RTA_OK(rta, len)) {
        if (rta->rta_type <= RTA_MAX)
            attrs[rta->rta_type] = rta;
        rta = RTA_NEXT(rta, len);
    }
}

void
error_reply(char *msg)
{
    int err = RTM_CMD_ROUTE_ERR;
    size_t len = strlen(msg);
    struct iovec iov[3];

    iov[0].iov_base = &err;
    iov[0].iov_len  = 1;
    iov[1].iov_base = &len;
    iov[1].iov_len  = 1;
    iov[2].iov_base = msg;
    iov[2].iov_len  = len;

    writev(STDOUT_FILENO, iov, sizeof(iov)/sizeof(iov[0]));
}

void
error_quit(char *msg)
{
    char buf[BUFSIZE];
    if (errno == 0)
        snprintf(buf, BUFSIZE, "%s", msg);
    else
        snprintf(buf, BUFSIZE, "%s: %s", msg, strerror(errno));
    error_reply(buf);
    exit(1);
}

void
notify(const struct sockaddr_nl *nlp, struct nlmsghdr *nlmsgp)
{
    int len;
    int host_len;
    unsigned char cmd;
    struct in_addr any;
    struct iovec iov[NUM_RESP];
    struct rtmsg *rtmp;
    struct rtattr *attrs[RTA_MAX + 1];

    switch (nlmsgp->nlmsg_type) {
    case RTM_NEWROUTE:
        cmd = RTM_CMD_ROUTE_ADD;
        break;
    case RTM_DELROUTE:
        cmd = RTM_CMD_ROUTE_DEL;
        break;
    default:
        error_reply("not a route");
        return;
    }

    len = nlmsgp->nlmsg_len - NLMSG_LENGTH(sizeof(*nlmsgp));
    if (len < 0) {
        error_reply("wrong message length");
        return;
    }

    rtmp = NLMSG_DATA(nlmsgp);

    /* Don't notify routes added by ourselves. */
    if (rtmp->rtm_protocol == RTPROT_ROUTEMACHINE)
        return;

    if (rtmp->rtm_table != RT_TABLE_MAIN)
        return;

    switch (rtmp->rtm_family) {
    case AF_INET:
        host_len = 4;
        break;
    case AF_INET6:
        host_len = 16;
        break;
    default:
        error_reply("bad message family");
        return;
    }

    parse_attrs(attrs, RTM_RTA(rtmp), len);

    iov[CMD].iov_base = &cmd;
    iov[CMD].iov_len  = 1;

    iov[MASK].iov_base = &rtmp->rtm_dst_len;
    iov[MASK].iov_len  = 1;

    any.s_addr = INADDR_ANY;

    if (attrs[RTA_DST] != NULL) {
        iov[DST].iov_base = RTA_DATA(attrs[RTA_DST]);
        iov[DST].iov_len  = (rtmp->rtm_dst_len + 7)/8;
    } else {
        iov[DST].iov_base = &any;
        iov[DST].iov_len  = sizeof(any);
    }

    if (attrs[RTA_GATEWAY] != NULL) {
        iov[GW].iov_base = RTA_DATA(attrs[RTA_GATEWAY]);
        iov[GW].iov_len  = host_len;
    } else {
        iov[GW].iov_base = &any;
        iov[GW].iov_len  = sizeof(any);
    }

    if (attrs[RTA_PRIORITY] != NULL) {
        uint32_t prio = htonl(*(uint32_t *)RTA_DATA(attrs[RTA_PRIORITY]));
        iov[PRIO].iov_base = &prio;
        iov[PRIO].iov_len = 4;
    } else {
        uint32_t prio = htonl(0);
        iov[PRIO].iov_base = &prio;
        iov[PRIO].iov_len = 4;
    }

    writev(STDOUT_FILENO, iov, NUM_RESP);
}

int
bind_socket(void)
{
    int sock;
    int ret;
    struct sockaddr_nl nl;
    int sndbuf = 32768;
    int rcvbuf = 1048576;

    sock = socket(PF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (sock == -1)
        error_quit("socket");

    ret = setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
    if (ret == -1)
        error_quit("setsockopt[SO_SNDBUF]");

    ret = setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    if (ret == -1)
        error_quit("setsockopt[SO_RCVBUF]");

    memset(&nl, 0, sizeof(nl));
    nl.nl_family = AF_NETLINK;
    nl.nl_groups = RTMGRP_LINK
                 | RTMGRP_IPV4_IFADDR | RTMGRP_IPV4_ROUTE
                 | RTMGRP_IPV6_IFADDR | RTMGRP_IPV6_ROUTE;

    ret = bind(sock, (struct sockaddr *)&nl, sizeof(nl));
    if (ret == -1)
        error_quit("bind");

    return sock;
}

void
read_routes(int sock)
{
    int ret;
    struct sockaddr_nl nl;
    struct iovec iov;
    struct msghdr msg;
    struct nlmsghdr *p;
    char buf[BUFSIZE];

    msg.msg_name = &nl;
    msg.msg_namelen = sizeof(nl);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;

    memset(&nl, 0, sizeof(nl));
    nl.nl_family = AF_NETLINK;
    nl.nl_pid = 0;
    nl.nl_groups = 0;

    iov.iov_base = buf;
    iov.iov_len = BUFSIZE;

    ret = recvmsg(sock, &msg, 0);
    if (ret == -1) {
        if (errno == EINTR || errno == EAGAIN || errno == ENOBUFS)
            return;
        error_quit("recvmsg");
    }
    if (ret == 0)
        error_quit("recvmsg: EOF");

    if (msg.msg_namelen != sizeof(nl))
        error_quit("bad message namelen");

    p = (struct nlmsghdr *)buf;
    while (ret >= sizeof(*p)) {
        int len = p->nlmsg_len;

        if (len < sizeof(*p) || len > ret) {
            if (msg.msg_flags & MSG_TRUNC)
                error_quit("truncated message");
            error_quit("malformed message");
        }

        if (p->nlmsg_type != NLMSG_DONE)
            notify(&nl, p);

        ret -= NLMSG_ALIGN(len);
        p = (struct nlmsghdr*)((char*)p + NLMSG_ALIGN(len));
    }
    if (msg.msg_flags & MSG_TRUNC)
        return;
    if (ret != 0)
        error_quit("unexpected remaining bytes");
}

void
request_dump(int sock)
{
    struct {
        struct nlmsghdr nlmsg;
        struct rtgenmsg rtgen;
    } req;

    memset(&req, 0, sizeof(req));
    req.nlmsg.nlmsg_len = sizeof(req);
    req.nlmsg.nlmsg_type = RTM_GETROUTE;
    req.nlmsg.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    req.nlmsg.nlmsg_pid = 0;
    req.nlmsg.nlmsg_seq = 1;
    req.rtgen.rtgen_family = AF_UNSPEC;

    send(sock, &req, sizeof(req), 0);
}

void
set_nonblock(int fd)
{
    int res;

    res = fcntl(fd, F_GETFL, 0);
    if (res == -1)
        error_quit("fcntl[F_GETFL]");
    res = fcntl(fd, F_SETFL, res | O_NONBLOCK);
    if (res == -1)
        error_quit("fcntl[F_SETFL]");
}

int
main(int argc, char **argv)
{
    int sock;
    fd_set rset, wset;

    sock = bind_socket();

    set_nonblock(STDIN_FILENO);
    set_nonblock(sock);

    FD_ZERO(&rset);
    FD_ZERO(&wset);

    FD_SET(sock, &wset);

    for (;;) {
        int res;
        ssize_t n;

        FD_SET(STDIN_FILENO, &rset);
        FD_SET(sock, &rset);

        res = select(sock + 1, &rset, &wset, NULL, NULL);
        if (res == -1)
            error_quit("select");

        if (FD_ISSET(STDIN_FILENO, &rset)) {
            char buf[1];
            n = read(STDIN_FILENO, buf, 1);
            if (n == -1 && errno != EWOULDBLOCK)
                error_quit("read");
            else if (n == 0) {
                close(sock);
                exit(0);  /* got EOF from erlang */
            }
        }

        if (FD_ISSET(sock, &wset)) {
            FD_CLR(sock, &wset);
            request_dump(sock);
            read_routes(sock);
        }

        if (FD_ISSET(sock, &rset))
            read_routes(sock);
    }

    return 0;
}
