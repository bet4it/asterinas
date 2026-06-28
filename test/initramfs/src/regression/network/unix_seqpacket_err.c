// SPDX-License-Identifier: MPL-2.0

#define SOCK_TYPE SOCK_SEQPACKET
#include "unix_streamlike_prologue.h"

FN_TEST(sendto)
{
	char buf[1] = { 'z' };

	TEST_ERRNO(sendto(sk_unbound, buf, 1, 0, &LISTEN_ADDR, LISTEN_ADDRLEN),
		   ENOTCONN);
	TEST_ERRNO(sendto(sk_bound, buf, 1, 0, &LISTEN_ADDR2, LISTEN_ADDRLEN2),
		   ENOTCONN);
	TEST_ERRNO(sendto(sk_listen, buf, 1, 0, &BOUND_ADDR, BOUND_ADDRLEN),
		   ENOTCONN);
}
END_TEST()

FN_TEST(send_recv_trunc)
{
	int fildes[2];
	char buf[1];

	TEST_SUCC(
		socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK, 0, fildes));

	TEST_SUCC(send(fildes[0], "abc", 3, 0));
	TEST_SUCC(send(fildes[0], "def", 3, 0));
	TEST_SUCC(send(fildes[0], "hij", 3, 0));

	TEST_RES(recv(fildes[1], buf, 1, 0), _ret == 1 && buf[0] == 'a');
	TEST_RES(recv(fildes[1], buf, 0, 0), _ret == 0);
	TEST_RES(recv(fildes[1], buf, 1, 0), _ret == 1 && buf[0] == 'h');

	TEST_SUCC(close(fildes[0]));
	TEST_SUCC(close(fildes[1]));
}
END_TEST()

FN_TEST(send_recv_zero)
{
	int fildes[2];
	char buf[1];

	TEST_SUCC(
		socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK, 0, fildes));

	buf[0] = 'a';
	TEST_SUCC(send(fildes[0], buf, 1, 0));
	buf[0] = 'b';
	TEST_SUCC(send(fildes[0], buf, 0, 0));
	buf[0] = 'c';
	TEST_SUCC(send(fildes[0], buf, 0, 0));
	buf[0] = 'd';
	TEST_SUCC(send(fildes[0], buf, 1, 0));

	TEST_RES(recv(fildes[1], buf, 1, 0), _ret == 1 && buf[0] == 'a');
	TEST_RES(recv(fildes[1], buf, 1, 0), _ret == 0 && buf[0] == 'a');
	TEST_RES(recv(fildes[1], buf, 1, 0), _ret == 0 && buf[0] == 'a');
	TEST_RES(recv(fildes[1], buf, 1, 0), _ret == 1 && buf[0] == 'd');

	TEST_SUCC(close(fildes[0]));
	TEST_SUCC(close(fildes[1]));
}
END_TEST()

FN_TEST(recv_peek_trunc_probe)
{
	int fildes[2];
	char buf[3];

	TEST_SUCC(socketpair(AF_UNIX, SOCK_SEQPACKET, 0, fildes));

	TEST_RES(send(fildes[0], "abc", 3, 0), _ret == 3);
	TEST_RES(recv(fildes[1], NULL, 0, MSG_PEEK | MSG_TRUNC), _ret == 3);
	TEST_RES(recv(fildes[1], buf, sizeof(buf), 0),
		 _ret == 3 && memcmp(buf, "abc", 3) == 0);

	TEST_SUCC(close(fildes[0]));
	TEST_SUCC(close(fildes[1]));
}
END_TEST()

FN_TEST(recv_trunc_returns_record_len)
{
	int fildes[2];
	char buf[3] = {};

	TEST_SUCC(socketpair(AF_UNIX, SOCK_SEQPACKET, 0, fildes));

	TEST_RES(send(fildes[0], "abc", 3, 0), _ret == 3);
	TEST_RES(send(fildes[0], "def", 3, 0), _ret == 3);
	TEST_RES(recv(fildes[1], buf, 1, MSG_TRUNC),
		 _ret == 3 && buf[0] == 'a');
	TEST_RES(recv(fildes[1], buf, sizeof(buf), 0),
		 _ret == 3 && memcmp(buf, "def", 3) == 0);

	TEST_SUCC(close(fildes[0]));
	TEST_SUCC(close(fildes[1]));
}
END_TEST()

#include "unix_streamlike_epilogue.h"
