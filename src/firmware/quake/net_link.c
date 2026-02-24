/*
Copyright (C) 1996-1997 Id Software, Inc.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

*/
// net_link.c -- Pocket link-cable transport over MMIO FIFO

#include "quakedef.h"
#include "net_link.h"

/*
 * MMIO contract (proposed / expected by this driver):
 *
 * Base: 0x4D000000
 *   +0x00 LINK_ID      RO  Must read 0x4C4E4B31 ("LNK1")
 *   +0x04 LINK_VER     RO  Bitfield version/caps (optional, currently unused)
 *   +0x08 LINK_STATUS  RO  [0]=link_up [1]=peer_present [2]=tx_full [3]=rx_empty
 *                           [4]=rx_crc_err [5]=rx_overflow [6]=tx_overflow [7]=desync
 *   +0x0C LINK_CTRL    WO  [0]=enable [1]=reset [2]=clear_err [3]=flush_rx [4]=flush_tx
 *                           [5]=master [6]=poll
 *   +0x10 LINK_TX_DATA WO  Push one 32-bit transport word
 *   +0x14 LINK_RX_DATA RO  Pop one 32-bit transport word
 *   +0x18 LINK_TX_SPACE RO Number of free TX words
 *   +0x1C LINK_RX_COUNT RO Number of queued RX words
 *
 * Frame format on TX/RX word stream:
 *   W0: 0x51464D45 ("QFME")
 *   W1: [31:24]=type [23:16]=seq [15:0]=payload_len_bytes
 *   W2: [15:0]=CRC16(type,seq,len_lo,len_hi,payload...)
 *   W3..: payload (little-endian bytes), padded to 32-bit boundary
 */

#ifndef POCKET_LINK_ENABLE
#define POCKET_LINK_ENABLE 0
#endif

#if POCKET_LINK_ENABLE

#define LINK_MMIO_BASE			0x4D000000u
#define LINK_REG_ID				0x00u
#define LINK_REG_VER			0x04u
#define LINK_REG_STATUS			0x08u
#define LINK_REG_CTRL			0x0Cu
#define LINK_REG_TX_DATA		0x10u
#define LINK_REG_RX_DATA		0x14u
#define LINK_REG_TX_SPACE		0x18u
#define LINK_REG_RX_COUNT		0x1Cu

#define LINK_HW_ID				0x4C4E4B31u	// "LNK1"
#define LINK_FRAME_MAGIC		0x51464D45u	// "QFME"

#define LINK_CTRL_ENABLE		(1u << 0)
#define LINK_CTRL_RESET			(1u << 1)
#define LINK_CTRL_CLEAR_ERR		(1u << 2)
#define LINK_CTRL_FLUSH_RX		(1u << 3)
#define LINK_CTRL_FLUSH_TX		(1u << 4)
#define LINK_CTRL_MASTER		(1u << 5)
#define LINK_CTRL_POLL			(1u << 6)

#define LINK_STATUS_LINK_UP		(1u << 0)
#define LINK_STATUS_PEER		(1u << 1)
#define LINK_STATUS_TX_FULL		(1u << 2)
#define LINK_STATUS_RX_EMPTY	(1u << 3)

#define LINK_PKT_HELLO			1
#define LINK_PKT_HELLO_ACK		2
#define LINK_PKT_RELIABLE		3
#define LINK_PKT_RELIABLE_ACK	4
#define LINK_PKT_UNRELIABLE		5
#define LINK_PKT_KEEPALIVE		6
#define LINK_PKT_RESET			7

#define LINK_STATE_DOWN			0
#define LINK_STATE_HANDSHAKE	1
#define LINK_STATE_CONNECTED	2

#define LINK_RX_WAIT_MAGIC		0
#define LINK_RX_WAIT_HEADER		1
#define LINK_RX_WAIT_CRC		2
#define LINK_RX_WAIT_PAYLOAD	3

#define LINK_MAX_PAYLOAD		MAX_MSGLEN
#define LINK_POLL_WORD_BUDGET	128
#define LINK_CONNECT_TIMEOUT	2.0
#define LINK_HELLO_INTERVAL		0.10
#define LINK_RETRY_INTERVAL		0.05
#define LINK_KEEPALIVE_INTERVAL	0.50
#define LINK_PEER_TIMEOUT		2.00
#define LINK_MAX_RETRIES		20

static qboolean	link_hw_present = false;
static qboolean	link_listening = false;
static qsocket_t *link_socket = NULL;
static qboolean	link_server_side = false;
static unsigned int	link_ctrl_role = 0;
static qboolean	link_incoming_pending = false;
static int		link_state = LINK_STATE_DOWN;
static qboolean	link_transport_dead = false;
static qboolean	link_sending_frame = false;
static unsigned int	link_rx_word_count = 0;
static unsigned int	link_rx_frame_count = 0;
static unsigned int	link_rx_crc_fail_count = 0;

static byte		link_tx_rel_seq = 0;
static byte		link_rx_rel_seq = 0;
static qboolean	link_waiting_ack = false;
static byte		link_pending_seq = 0;
static byte		link_pending_data[LINK_MAX_PAYLOAD];
static int		link_pending_len = 0;
static float	link_pending_sent_at = 0.0f;
static int		link_pending_retries = 0;
static float	link_last_rx_time = 0.0f;
static float	link_last_tx_time = 0.0f;
static float	link_last_hello_time = 0.0f;
static float	link_handshake_start = 0.0f;

static int		link_rx_state = LINK_RX_WAIT_MAGIC;
static byte		link_rx_type = 0;
static byte		link_rx_seq = 0;
static unsigned short	link_rx_len = 0;
static unsigned short	link_rx_crc = 0;
static int		link_rx_words_needed = 0;
static int		link_rx_words_seen = 0;
static byte		link_rx_payload[LINK_MAX_PAYLOAD];

static float Link_TimeNow(void)
{
	return Sys_FloatTime();
}

static int IntAlign(int value)
{
	return (value + (sizeof(int) - 1)) & (~(sizeof(int) - 1));
}

static unsigned int Link_ReadReg(unsigned int offset)
{
	volatile unsigned int *reg = (volatile unsigned int *)(LINK_MMIO_BASE + offset);
	return *reg;
}

static void Link_WriteReg(unsigned int offset, unsigned int value)
{
	volatile unsigned int *reg = (volatile unsigned int *)(LINK_MMIO_BASE + offset);
	*reg = value;
}

static void Link_ApplyCtrl(unsigned int pulse_flags)
{
	Link_WriteReg(LINK_REG_CTRL, LINK_CTRL_ENABLE | link_ctrl_role | pulse_flags);
}

static void Link_SetRole(qboolean master)
{
	if (master)
		link_ctrl_role = LINK_CTRL_MASTER | LINK_CTRL_POLL;
	else
		link_ctrl_role = 0;

	Link_ApplyCtrl(LINK_CTRL_CLEAR_ERR | LINK_CTRL_FLUSH_RX | LINK_CTRL_FLUSH_TX);
	Link_ApplyCtrl(LINK_CTRL_CLEAR_ERR);
}

static unsigned short Link_CRC16_Update(unsigned short crc, byte data)
{
	int i;

	crc ^= ((unsigned short)data) << 8;
	for (i = 0; i < 8; i++)
	{
		if (crc & 0x8000)
			crc = (unsigned short)((crc << 1) ^ 0x1021);
		else
			crc <<= 1;
	}

	return crc;
}

static unsigned short Link_FrameCRC(byte type, byte seq, const byte *payload, int payload_len)
{
	unsigned short crc;
	int i;

	crc = 0xFFFF;
	crc = Link_CRC16_Update(crc, type);
	crc = Link_CRC16_Update(crc, seq);
	crc = Link_CRC16_Update(crc, (byte)(payload_len & 0xFF));
	crc = Link_CRC16_Update(crc, (byte)((payload_len >> 8) & 0xFF));

	for (i = 0; i < payload_len; i++)
		crc = Link_CRC16_Update(crc, payload[i]);

	return crc;
}

static void Link_ResetParser(void)
{
	link_rx_state = LINK_RX_WAIT_MAGIC;
	link_rx_type = 0;
	link_rx_seq = 0;
	link_rx_len = 0;
	link_rx_crc = 0;
	link_rx_words_needed = 0;
	link_rx_words_seen = 0;
}

static void Link_MarkTransportDead(const char *reason)
{
	Con_Printf("Link: DEAD reason=%s\n", reason);
	link_transport_dead = true;
	link_state = LINK_STATE_DOWN;
	link_waiting_ack = false;
	link_pending_len = 0;
	link_pending_retries = 0;

	if (link_socket)
		link_socket->canSend = false;
}

static void Link_ResetSession(void)
{
	link_server_side = false;
	link_incoming_pending = false;
	link_state = LINK_STATE_DOWN;
	link_transport_dead = false;
	link_sending_frame = false;
	link_tx_rel_seq = 0;
	link_rx_rel_seq = 0;
	link_waiting_ack = false;
	link_pending_seq = 0;
	link_pending_len = 0;
	link_pending_sent_at = 0.0;
	link_pending_retries = 0;
	link_last_rx_time = 0.0;
	link_last_tx_time = 0.0;
	link_last_hello_time = 0.0;
	link_handshake_start = 0.0;
	Link_ResetParser();
}

static qboolean Link_QueueSocketMessage(qsocket_t *sock, int msgtype, const byte *data, int len)
{
	byte	*buffer;
	int		newlen;

	if (!sock)
		return false;

	if (len < 0 || len > LINK_MAX_PAYLOAD)
		return false;

	newlen = IntAlign(sock->receiveMessageLength + len + 4);
	if (newlen > NET_MAXMESSAGE)
		return false;

	buffer = sock->receiveMessage + sock->receiveMessageLength;

	buffer[0] = (byte)msgtype;
	buffer[1] = (byte)(len & 0xFF);
	buffer[2] = (byte)((len >> 8) & 0xFF);
	buffer[3] = 0;

	if (len > 0)
		Q_memcpy(buffer + 4, data, len);

	sock->receiveMessageLength = newlen;
	sock->lastMessageTime = Link_TimeNow();

	return true;
}

static void Link_PumpRx(void);

static qboolean Link_TxWaitSpace(int words)
{
	int spins = 0;
	unsigned int space;

	while (spins < 500000)
	{
		Link_PumpRx();

		if (!(Link_ReadReg(LINK_REG_STATUS) & LINK_STATUS_TX_FULL))
		{
			space = Link_ReadReg(LINK_REG_TX_SPACE) & 0xFFFFu;
			if (space >= (unsigned int)words)
				return true;
		}
		spins++;
	}
	return false;
}

static qboolean Link_SendFrame(byte type, byte seq, const byte *payload, int payload_len)
{
	int i;
	unsigned int word;
	unsigned short crc;

	if (!link_hw_present)
		return false;

	// Re-entrancy guard: Link_TxWaitSpace→Link_PumpRx can trigger
	// Link_OnReliable→Link_SendFrame(ACK). Skip the inner send to
	// avoid interleaving frames in the TX FIFO. Peer will retransmit.
	if (link_sending_frame)
		return false;

	if (payload_len < 0 || payload_len > LINK_MAX_PAYLOAD)
		return false;

	link_sending_frame = true;

	crc = Link_FrameCRC(type, seq, payload, payload_len);

	// Write header (3 words) — wait for space first
	if (!Link_TxWaitSpace(3))
	{
		link_sending_frame = false;
		return false;
	}

	Link_WriteReg(LINK_REG_TX_DATA, LINK_FRAME_MAGIC);
	Link_WriteReg(LINK_REG_TX_DATA,
		(((unsigned int)type) << 24) |
		(((unsigned int)seq) << 16) |
		((unsigned int)payload_len & 0xFFFFu));
	Link_WriteReg(LINK_REG_TX_DATA, (unsigned int)crc);

	// Write payload words, waiting for FIFO space as needed
	for (i = 0; i < payload_len; i += 4)
	{
		if (!Link_TxWaitSpace(1))
		{
			link_sending_frame = false;
			return false;
		}

		word = 0;
		word |= (unsigned int)payload[i + 0];
		if (i + 1 < payload_len) word |= ((unsigned int)payload[i + 1]) << 8;
		if (i + 2 < payload_len) word |= ((unsigned int)payload[i + 2]) << 16;
		if (i + 3 < payload_len) word |= ((unsigned int)payload[i + 3]) << 24;
		Link_WriteReg(LINK_REG_TX_DATA, word);
	}

	link_sending_frame = false;
	link_last_tx_time = Link_TimeNow();
	return true;
}

static void Link_OnHello(void)
{
	float now;

	Con_Printf("Link: HELLO rx (listening=%d state=%d)\n", link_listening, link_state);

	if (!link_listening)
		return;

	// If already connected, just re-ACK (client retransmitted before seeing our ACK)
	if (link_state == LINK_STATE_CONNECTED)
	{
		(void)Link_SendFrame(LINK_PKT_HELLO_ACK, 0, NULL, 0);
		return;
	}

	now = Link_TimeNow();

	if (!link_socket)
	{
		link_socket = NET_NewQSocket();
		if (!link_socket)
		{
			Con_Printf("Link: no qsocket for incoming connection\n");
			return;
		}

		Q_strcpy(link_socket->address, "gba-link:peer");
		link_socket->receiveMessageLength = 0;
		link_socket->sendMessageLength = 0;
		link_socket->canSend = true;
	}

	link_server_side = true;
	Link_SetRole(false);
	link_state = LINK_STATE_CONNECTED;
	link_transport_dead = false;
	link_incoming_pending = true;
	link_waiting_ack = false;
	link_pending_len = 0;
	link_pending_retries = 0;
	link_tx_rel_seq = 0;
	link_rx_rel_seq = 0;
	link_last_rx_time = now;
	link_last_tx_time = now;

	if (link_socket)
	{
		link_socket->canSend = true;
		link_socket->lastMessageTime = now;
	}

	(void)Link_SendFrame(LINK_PKT_HELLO_ACK, 0, NULL, 0);
}

static void Link_OnHelloAck(void)
{
	float now;

	Con_Printf("Link: HELLO_ACK rx\n");

	if (!link_socket || link_server_side)
		return;

	if (link_state != LINK_STATE_HANDSHAKE)
		return;

	now = Link_TimeNow();
	link_state = LINK_STATE_CONNECTED;
	link_transport_dead = false;
	link_last_rx_time = now;
	link_last_tx_time = now;
	link_pending_retries = 0;
	link_socket->canSend = true;
	link_socket->lastMessageTime = now;
}

static void Link_OnReliable(byte seq, const byte *payload, int len)
{
	byte last_good;

	if (!link_socket || link_state != LINK_STATE_CONNECTED)
		return;

	if (seq == link_rx_rel_seq)
	{
		if (!Link_QueueSocketMessage(link_socket, 1, payload, len))
		{
			Con_Printf("Link: reliable receive queue overflow\n");
			Link_MarkTransportDead("rx_queue_overflow");
			return;
		}

		link_rx_rel_seq++;
		(void)Link_SendFrame(LINK_PKT_RELIABLE_ACK, seq, NULL, 0);
		return;
	}

	last_good = (byte)(link_rx_rel_seq - 1);
	if (seq == last_good)
	{
		// Duplicate packet, resend ACK.
		(void)Link_SendFrame(LINK_PKT_RELIABLE_ACK, seq, NULL, 0);
		return;
	}

	// Unexpected seq: tell peer what we last accepted.
	(void)Link_SendFrame(LINK_PKT_RELIABLE_ACK, last_good, NULL, 0);
}

static void Link_OnReliableAck(byte seq)
{
	if (!link_waiting_ack)
		return;

	if (seq != link_pending_seq)
		return;

	link_waiting_ack = false;
	link_pending_len = 0;
	link_pending_retries = 0;

	if (link_socket)
		link_socket->canSend = true;
}

static void Link_HandleFrame(byte type, byte seq, const byte *payload, int payload_len)
{
	link_last_rx_time = Link_TimeNow();
	link_rx_frame_count++;

	switch (type)
	{
	case LINK_PKT_HELLO:
		Link_OnHello();
		break;

	case LINK_PKT_HELLO_ACK:
		Link_OnHelloAck();
		break;

	case LINK_PKT_RELIABLE:
		Link_OnReliable(seq, payload, payload_len);
		break;

	case LINK_PKT_RELIABLE_ACK:
		Link_OnReliableAck(seq);
		break;

	case LINK_PKT_UNRELIABLE:
		if (link_socket && link_state == LINK_STATE_CONNECTED)
		{
			// Drop if queue full (unreliable semantics).
			(void)Link_QueueSocketMessage(link_socket, 2, payload, payload_len);
		}
		break;

	case LINK_PKT_KEEPALIVE:
		break;

	case LINK_PKT_RESET:
		Link_MarkTransportDead("reset_pkt");
		break;

	default:
		break;
	}
}

static void Link_ConsumeRxWord(unsigned int word)
{
	int base;
	unsigned short crc;

	switch (link_rx_state)
	{
	case LINK_RX_WAIT_MAGIC:
		if (word == LINK_FRAME_MAGIC)
			link_rx_state = LINK_RX_WAIT_HEADER;
		return;

	case LINK_RX_WAIT_HEADER:
		link_rx_type = (byte)((word >> 24) & 0xFF);
		link_rx_seq = (byte)((word >> 16) & 0xFF);
		link_rx_len = (unsigned short)(word & 0xFFFF);

		if (link_rx_len > LINK_MAX_PAYLOAD)
		{
			Link_ResetParser();
			return;
		}

		link_rx_words_needed = (link_rx_len + 3) >> 2;
		link_rx_words_seen = 0;
		link_rx_state = LINK_RX_WAIT_CRC;
		return;

	case LINK_RX_WAIT_CRC:
		link_rx_crc = (unsigned short)(word & 0xFFFF);
		if (link_rx_words_needed == 0)
		{
			crc = Link_FrameCRC(link_rx_type, link_rx_seq, link_rx_payload, 0);
			if (crc == link_rx_crc)
				Link_HandleFrame(link_rx_type, link_rx_seq, link_rx_payload, 0);
			else
			{
				link_rx_crc_fail_count++;
				Con_Printf("Link: CRC FAIL type=%u len=0 got=%04x want=%04x\n",
					link_rx_type, link_rx_crc, crc);
			}
			Link_ResetParser();
			return;
		}

		link_rx_state = LINK_RX_WAIT_PAYLOAD;
		return;

	case LINK_RX_WAIT_PAYLOAD:
		base = link_rx_words_seen * 4;
		if (base + 0 < link_rx_len) link_rx_payload[base + 0] = (byte)(word & 0xFF);
		if (base + 1 < link_rx_len) link_rx_payload[base + 1] = (byte)((word >> 8) & 0xFF);
		if (base + 2 < link_rx_len) link_rx_payload[base + 2] = (byte)((word >> 16) & 0xFF);
		if (base + 3 < link_rx_len) link_rx_payload[base + 3] = (byte)((word >> 24) & 0xFF);

		link_rx_words_seen++;
		if (link_rx_words_seen < link_rx_words_needed)
			return;

		crc = Link_FrameCRC(link_rx_type, link_rx_seq, link_rx_payload, link_rx_len);
		if (crc == link_rx_crc)
			Link_HandleFrame(link_rx_type, link_rx_seq, link_rx_payload, link_rx_len);
		else
		{
			unsigned int status;
			link_rx_crc_fail_count++;
			Con_Printf("Link: CRC FAIL type=%u len=%d got=%04x want=%04x\n",
				link_rx_type, link_rx_len, link_rx_crc, crc);
			status = Link_ReadReg(LINK_REG_STATUS);
			if (status & LINK_STATUS_LINK_UP)
				Link_ApplyCtrl(LINK_CTRL_CLEAR_ERR);
		}

		Link_ResetParser();
		return;

	default:
		break;
	}

	Link_ResetParser();
}

static void Link_PumpRx(void)
{
	int i;
	unsigned int status;

	for (i = 0; i < LINK_POLL_WORD_BUDGET; i++)
	{
		status = Link_ReadReg(LINK_REG_STATUS);
		if (status & LINK_STATUS_RX_EMPTY)
			return;

		link_rx_word_count++;
		Link_ConsumeRxWord(Link_ReadReg(LINK_REG_RX_DATA));
	}
}

static void Link_PollTimers(void)
{
	float now;

	now = Link_TimeNow();

	if (link_state == LINK_STATE_HANDSHAKE)
	{
		if ((now - link_last_hello_time) >= LINK_HELLO_INTERVAL)
		{
			if (Link_SendFrame(LINK_PKT_HELLO, 0, NULL, 0))
				link_last_hello_time = now;
		}

		if ((now - link_handshake_start) >= LINK_CONNECT_TIMEOUT)
			Link_MarkTransportDead("handshake_timeout");
		return;
	}

	if (link_state != LINK_STATE_CONNECTED)
		return;

	if (link_waiting_ack && ((now - link_pending_sent_at) >= LINK_RETRY_INTERVAL))
	{
		if (link_pending_retries >= LINK_MAX_RETRIES)
		{
			Con_Printf("Link: max retries seq=%u len=%d\n", link_pending_seq, link_pending_len);
			Link_MarkTransportDead("max_retries");
			return;
		}

		if (Link_SendFrame(LINK_PKT_RELIABLE, link_pending_seq, link_pending_data, link_pending_len))
		{
			link_pending_sent_at = now;
			link_pending_retries++;
		}
	}

	if ((now - link_last_tx_time) >= LINK_KEEPALIVE_INTERVAL)
		(void)Link_SendFrame(LINK_PKT_KEEPALIVE, 0, NULL, 0);

	if ((now - link_last_rx_time) >= LINK_PEER_TIMEOUT)
	{
		Con_Printf("Link: peer timeout %.2fs words=%u frames=%u crcfail=%u st=0x%x ctrl=0x%x\n",
			now - link_last_rx_time, link_rx_word_count, link_rx_frame_count,
			link_rx_crc_fail_count, Link_ReadReg(LINK_REG_STATUS),
			Link_ReadReg(LINK_REG_CTRL));
		Link_MarkTransportDead("peer_timeout");
	}
}

static void Link_Poll(void)
{
	if (!link_hw_present)
		return;

	Link_PumpRx();
	Link_PollTimers();
}

int Link_Init (void)
{
	unsigned int id;

	if (cls.state == ca_dedicated)
		return -1;

	link_hw_present = false;
	link_listening = false;
	link_socket = NULL;
	link_ctrl_role = 0;
	Link_ResetSession();
	tcpipAvailable = false;

	id = Link_ReadReg(LINK_REG_ID);
	if (id != LINK_HW_ID)
	{
		Con_Printf("Link: MMIO not detected (id=0x%08x)\n", id);
		return -1;
	}

	// Bring interface to a clean enabled state.
	Link_WriteReg(LINK_REG_CTRL, LINK_CTRL_RESET);
	Link_ApplyCtrl(LINK_CTRL_CLEAR_ERR | LINK_CTRL_FLUSH_RX | LINK_CTRL_FLUSH_TX);
	Link_ApplyCtrl(LINK_CTRL_CLEAR_ERR);

	(void)Link_ReadReg(LINK_REG_VER);
	link_hw_present = true;
	tcpipAvailable = true;
	Q_strcpy(my_tcpip_address, "link");
	return 0;
}

void Link_Shutdown (void)
{
	if (link_hw_present)
		Link_WriteReg(LINK_REG_CTRL, LINK_CTRL_RESET);

	link_socket = NULL;
	link_listening = false;
	link_hw_present = false;
	link_ctrl_role = 0;
	tcpipAvailable = false;
	Link_ResetSession();
}

void Link_Listen (qboolean state)
{
	link_listening = state;
	if (state && link_hw_present && link_state == LINK_STATE_DOWN)
		Link_SetRole(false);
	if (!state && link_server_side)
		link_incoming_pending = false;
}

void Link_SearchForHosts (qboolean xmit)
{
	int i;
	UNUSED(xmit);

	Link_Poll();

	if (!link_hw_present)
		return;

	// Don't add duplicate entries on repeated polls
	for (i = 0; i < hostCacheCount; i++)
		if (Q_strcmp(hostcache[i].cname, "link") == 0)
			return;

	if (hostCacheCount >= HOSTCACHESIZE)
		return;

	Q_strcpy(hostcache[hostCacheCount].name, "PocketLink");
	Q_strcpy(hostcache[hostCacheCount].map, sv.active ? sv.name : "");
	hostcache[hostCacheCount].users = sv.active ? net_activeconnections : 0;
	hostcache[hostCacheCount].maxusers = 2;
	hostcache[hostCacheCount].driver = net_driverlevel;
	Q_strcpy(hostcache[hostCacheCount].cname, "link");
	hostCacheCount++;
}

qsocket_t *Link_Connect (char *host)
{
	float deadline, next_dump;
	qsocket_t *sock;

	Con_Printf("Link_Connect(\"%s\") hw=%d\n", host, link_hw_present);

	if (!link_hw_present)
		return NULL;

	if (Q_strcmp(host, "link") && Q_strcmp(host, "PocketLink") && Q_strcmp(host, "gba-link"))
	{
		Con_Printf("Link: bad host \"%s\"\n", host);
		return NULL;
	}

	if (link_socket && !link_socket->disconnected)
	{
		Con_Printf("Link: already connected or pending\n");
		return NULL;
	}

	link_socket = NET_NewQSocket();
	if (!link_socket)
	{
		Con_Printf("Link: no qsocket available\n");
		return NULL;
	}

	Q_strcpy(link_socket->address, "gba-link:client");
	link_socket->receiveMessageLength = 0;
	link_socket->sendMessageLength = 0;
	link_socket->canSend = false;

	Link_ResetSession();
	link_server_side = false;
	link_rx_word_count = 0;
	Link_SetRole(true);
	link_state = LINK_STATE_HANDSHAKE;
	link_handshake_start = Link_TimeNow();
	link_last_hello_time = 0.0;
	link_last_rx_time = link_handshake_start;
	link_last_tx_time = link_handshake_start;

	Con_Printf("Link: ctrl=0x%x status=0x%x\n",
		LINK_CTRL_ENABLE | link_ctrl_role,
		Link_ReadReg(LINK_REG_STATUS));

	(void)Link_SendFrame(LINK_PKT_HELLO, 0, NULL, 0);
	link_last_hello_time = Link_TimeNow();

	deadline = Link_TimeNow() + LINK_CONNECT_TIMEOUT;
	next_dump = Link_TimeNow() + 0.5;
	while (Link_TimeNow() < deadline)
	{
		Link_Poll();
		if (link_state == LINK_STATE_CONNECTED && !link_transport_dead)
		{
			Con_Printf("Link: connected!\n");
			return link_socket;
		}
		if (Link_TimeNow() >= next_dump)
		{
			Con_Printf("Link: s=0x%x words=%u\n",
				Link_ReadReg(LINK_REG_STATUS),
				link_rx_word_count);
			next_dump += 0.5;
		}
	}

	Con_Printf("Link: timeout (status=0x%x rx_count=%u)\n",
		Link_ReadReg(LINK_REG_STATUS),
		Link_ReadReg(LINK_REG_RX_COUNT) & 0xFFFFu);
	sock = link_socket;
	Link_Close(sock);
	NET_FreeQSocket(sock);
	link_socket = NULL;
	return NULL;
}

qsocket_t *Link_CheckNewConnections (void)
{
	static int call_count = 0;

	call_count++;
	if (call_count <= 2)
		Con_Printf("Link: CheckNew #%d hw=%d lst=%d st=%d pend=%d\n",
			call_count, link_hw_present, link_listening, link_state, link_incoming_pending);

	Link_Poll();

	if (!link_hw_present || !link_listening)
		return NULL;

	if (link_transport_dead || link_state != LINK_STATE_CONNECTED)
		return NULL;

	if (!link_incoming_pending || !link_socket)
		return NULL;

	link_incoming_pending = false;
	link_socket->canSend = !link_waiting_ack;
	Con_Printf("Link: CheckNew returning socket\n");
	return link_socket;
}

int Link_GetMessage (qsocket_t *sock)
{
	int ret;
	int length;

	if (!sock || sock != link_socket)
		return -1;

	Link_Poll();

	if (link_transport_dead)
		return -1;

	if (sock->receiveMessageLength == 0)
		return 0;

	ret = sock->receiveMessage[0];
	length = sock->receiveMessage[1] + (sock->receiveMessage[2] << 8);

	SZ_Clear (&net_message);
	SZ_Write (&net_message, &sock->receiveMessage[4], length);

	length = IntAlign(length + 4);
	sock->receiveMessageLength -= length;

	if (sock->receiveMessageLength)
		Q_memcpy(sock->receiveMessage, &sock->receiveMessage[length], sock->receiveMessageLength);

	return ret;
}

int Link_SendMessage (qsocket_t *sock, sizebuf_t *data)
{
	if (!sock || sock != link_socket)
	{
		Con_Printf("Link: SendMsg FAIL sock=%p link=%p\n", sock, link_socket);
		return -1;
	}

	if (!data || data->cursize < 0 || data->cursize > LINK_MAX_PAYLOAD)
		return -1;

	Link_Poll();

	if (link_transport_dead)
	{
		Con_Printf("Link: SendMsg FAIL dead\n");
		return -1;
	}

	if (link_state != LINK_STATE_CONNECTED)
	{
		Con_Printf("Link: SendMsg FAIL state=%d\n", link_state);
		return 0;
	}

	if (link_waiting_ack)
		return 0;

	if (!Link_SendFrame(LINK_PKT_RELIABLE, link_tx_rel_seq, data->data, data->cursize))
	{
		Con_Printf("Link: SendMsg FAIL frame\n");
		return 0;
	}

	Q_memcpy(link_pending_data, data->data, data->cursize);
	link_pending_len = data->cursize;
	link_pending_seq = link_tx_rel_seq;
	link_pending_sent_at = Link_TimeNow();
	link_pending_retries = 0;
	link_waiting_ack = true;
	link_tx_rel_seq++;
	sock->canSend = false;
	return 1;
}

int Link_SendUnreliableMessage (qsocket_t *sock, sizebuf_t *data)
{
	if (!sock || sock != link_socket)
		return -1;

	if (!data || data->cursize < 0 || data->cursize > LINK_MAX_PAYLOAD)
		return 0;

	Link_Poll();

	if (link_transport_dead)
		return -1;

	if (link_state != LINK_STATE_CONNECTED)
		return 0;

	if (!Link_SendFrame(LINK_PKT_UNRELIABLE, 0, data->data, data->cursize))
		return 0;

	return 1;
}

qboolean Link_CanSendMessage (qsocket_t *sock)
{
	if (!sock || sock != link_socket)
		return false;

	Link_Poll();

	if (link_transport_dead || link_state != LINK_STATE_CONNECTED)
		return false;

	return !link_waiting_ack;
}

qboolean Link_CanSendUnreliableMessage (qsocket_t *sock)
{
	unsigned int status;

	if (!sock || sock != link_socket)
		return false;

	Link_Poll();

	if (link_transport_dead || link_state != LINK_STATE_CONNECTED)
		return false;

	status = Link_ReadReg(LINK_REG_STATUS);
	return (status & LINK_STATUS_TX_FULL) ? false : true;
}

void Link_Close (qsocket_t *sock)
{
	if (!sock)
		return;

	if (link_hw_present && link_state == LINK_STATE_CONNECTED)
		(void)Link_SendFrame(LINK_PKT_RESET, 0, NULL, 0);

	if (sock == link_socket)
		link_socket = NULL;

	sock->receiveMessageLength = 0;
	sock->sendMessageLength = 0;
	sock->canSend = true;

	Link_ResetSession();
	if (link_hw_present)
		Link_SetRole(false);
}

#else

int Link_Init (void)
{
	return -1;
}

void Link_Listen (qboolean state)
{
	UNUSED(state);
}

void Link_SearchForHosts (qboolean xmit)
{
	UNUSED(xmit);
}

qsocket_t *Link_Connect (char *host)
{
	UNUSED(host);
	return NULL;
}

qsocket_t *Link_CheckNewConnections (void)
{
	return NULL;
}

int Link_GetMessage (qsocket_t *sock)
{
	UNUSED(sock);
	return 0;
}

int Link_SendMessage (qsocket_t *sock, sizebuf_t *data)
{
	UNUSED(sock);
	UNUSED(data);
	return -1;
}

int Link_SendUnreliableMessage (qsocket_t *sock, sizebuf_t *data)
{
	UNUSED(sock);
	UNUSED(data);
	return -1;
}

qboolean Link_CanSendMessage (qsocket_t *sock)
{
	UNUSED(sock);
	return false;
}

qboolean Link_CanSendUnreliableMessage (qsocket_t *sock)
{
	UNUSED(sock);
	return false;
}

void Link_Close (qsocket_t *sock)
{
	UNUSED(sock);
}

void Link_Shutdown (void)
{
}

#endif
