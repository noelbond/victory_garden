#ifndef __LWIPOPTS_H__
#define __LWIPOPTS_H__

#define NO_SYS                          1
#define MEM_ALIGNMENT                   4
#define MEM_SIZE                        (16 * 1024)
#define MEMP_NUM_SYS_TIMEOUT            16
#define MEMP_NUM_NETBUF                 8
#define MEMP_NUM_TCPIP_MSG_API          16
#define MEMP_NUM_TCP_SEG                32
#define PBUF_POOL_SIZE                  24
#define PBUF_POOL_BUFSIZE               512

#define LWIP_RAW                        1
#define LWIP_NETCONN                    0
#define LWIP_SOCKET                     0

#define LWIP_ARP                        1
#define LWIP_ETHERNET                   1
#define LWIP_ICMP                       1
#define LWIP_UDP                        1
#define LWIP_TCP                        1
#define LWIP_IPV4                       1
#define LWIP_IPV6                       0
#define LWIP_DHCP                       1
#define LWIP_DNS                        1
#define DNS_TABLE_SIZE                  4

#define LWIP_NETIF_HOSTNAME             1
#define LWIP_NETIF_STATUS_CALLBACK      1
#define LWIP_NETIF_LINK_CALLBACK        1
#define LWIP_SINGLE_NETIF               1

#define TCP_MSS                         (1460)
#define TCP_SND_BUF                     (4 * TCP_MSS)
#define TCP_WND                         (4 * TCP_MSS)
#define TCP_SND_QUEUELEN                ((4 * TCP_SND_BUF) / TCP_MSS)

#define ETHARP_SUPPORT_STATIC_ENTRIES   1
#define LWIP_CHKSUM_ALGORITHM           3
#define LWIP_TIMEVAL_PRIVATE            0
#define MQTT_OUTPUT_RINGBUF_SIZE        1024

#endif
