// Copyright (c) 2016, XMOS Ltd, All rights reserved
#include <stddef.h>
#include <stdint.h>

#include "wifi_broadcom_wiced.h"
#include "wifi.h"
#include "spi.h"
#include "spi_fast.h"
#include "gpio.h"
#include "xc2compat.h"
#include "xc_broadcom_wiced_includes.h"
#include "lwip/pbuf.h"

#undef DEBUG_UNIT
#define DEBUG_UNIT WIFI_DEBUG
#include "debug_print.h"
#include "xassert.h"

typedef enum {
  WIFI_SYNCHRONOUS_SPI,
  WIFI_ASYNCHRONOUS_SPI,
  WIFI_FAST_SPI
} wifi_spi_type_t;

static const unsigned wifi_bcm_wiced_spi_speed_khz = 1000; // TODO: remove or use for both sync and async
static const spi_mode_t wifi_bcm_wiced_spi_mode = SPI_MODE_1; // XXX: M3 ARM code appears to use SPI_MODE_3, LPC17xx code appears to use SPI_MODE_0...
static const unsigned wifi_bcm_wiced_spi_ss_deassert_ms = 100;
static unsafe client interface spi_master_if i_wifi_bcm_wiced_spi;
static unsafe client interface spi_master_async_if i_wifi_bcm_wiced_async_spi;
static unsigned wifi_bcm_wiced_spi_device_index;
static spi_fast_ports * unsafe p_wifi_bcm_wiced_spi;
static wifi_spi_type_t wifi_spi_master_type_in_use;
#define WIFI_MAX_ASYNC_SPI_BUF_LEN 2000

signals_t signals;
unsafe streaming chanend xcore_wwd_pbuf_external;
unsafe client interface fs_basic_if i_fs_global;

// Function prototype for xcore wrapper function found in xcore_wrappers.c
void xcore_wifi_scan_networks();
unsigned xcore_wifi_join_network_at_index(size_t index, uint8_t security_key[],
                                          size_t key_length);
wwd_result_t xcore_wifi_get_radio_mac_address(wiced_mac_t * unsafe mac_address);

unsafe void xcore_wiced_drive_power_line (uint32_t line_state) {
  switch (wifi_spi_master_type_in_use) {
    case WIFI_SYNCHRONOUS_SPI:
      i_wifi_bcm_wiced_spi.drive_1bit_of_ss_port(0, 2, line_state);
      break;
    case WIFI_ASYNCHRONOUS_SPI:
      i_wifi_bcm_wiced_async_spi.drive_1bit_of_ss_port(0, 2, line_state);
      break;
    case WIFI_FAST_SPI:
      drive_cs_port_now(*p_wifi_bcm_wiced_spi, 2, line_state);
      break;
    default:
      unreachable("Must be WIFI_SYNCHRONOUS_SPI, WIFI_ASYNCHRONOUS_SPI, or"
                  "WIFI_FAST_SPI");
      break;
  }
}

unsafe void xcore_wiced_drive_reset_line(uint32_t line_state) {
  switch (wifi_spi_master_type_in_use) {
    case WIFI_SYNCHRONOUS_SPI:
      i_wifi_bcm_wiced_spi.drive_1bit_of_ss_port(0, 1, line_state);
      break;
    case WIFI_ASYNCHRONOUS_SPI:
      i_wifi_bcm_wiced_async_spi.drive_1bit_of_ss_port(0, 1, line_state);
      break;
    case WIFI_FAST_SPI:
      drive_cs_port_now(*p_wifi_bcm_wiced_spi, 1, line_state);
      break;
    default:
      unreachable("Must be WIFI_SYNCHRONOUS_SPI, WIFI_ASYNCHRONOUS_SPI, or"
                  "WIFI_FAST_SPI");
      break;
  }
}

unsafe void xcore_wiced_spi_transfer(wwd_bus_transfer_direction_t direction,
                                     uint8_t * unsafe buffer,
                                     uint16_t buffer_length) {
  switch (wifi_spi_master_type_in_use) {
    case WIFI_SYNCHRONOUS_SPI:
      i_wifi_bcm_wiced_spi.begin_transaction(wifi_bcm_wiced_spi_device_index,
                                             1000, // TODO: max this out - BCM supports 50MHz (currently breaks above 1MHz)
                                             wifi_bcm_wiced_spi_mode);
      if (BUS_READ == direction) {
        // Reading from the bus TO buffer
        for (int i = 0; i < buffer_length; i++) {
          buffer[i] = i_wifi_bcm_wiced_spi.transfer8(buffer[i]);
        }
      } else { // Must be BUS_WRITE
        // Writing to the bus FROM buffer, ignore received data
        for (int i = 0; i < buffer_length; i++) {
          i_wifi_bcm_wiced_spi.transfer8(buffer[i]);
        }
      }
      i_wifi_bcm_wiced_spi.end_transaction(wifi_bcm_wiced_spi_ss_deassert_ms);
      break;
    case WIFI_ASYNCHRONOUS_SPI:
      uint8_t read_data[WIFI_MAX_ASYNC_SPI_BUF_LEN];
      uint8_t * movable read_buf = read_data;
      uint8_t * movable write_buf = (uint8_t * movable)buffer;

      i_wifi_bcm_wiced_async_spi.begin_transaction(wifi_bcm_wiced_spi_device_index,
                                                   50000, // FIXME: just a starting point
                                                   wifi_bcm_wiced_spi_mode);
      if (BUS_READ == direction) {
        // Reading from the bus TO buffer
        xassert(buffer_length <= WIFI_MAX_ASYNC_SPI_BUF_LEN &&
          msg("WWD attempting SPI transaction with a buffer that's too big"));
        i_wifi_bcm_wiced_async_spi.init_transfer_array_8(move(read_buf),
                                                         move(write_buf),
                                                         buffer_length);
        select {
          case i_wifi_bcm_wiced_async_spi.transfer_complete():
            i_wifi_bcm_wiced_async_spi.retrieve_transfer_buffers_8(read_buf,
                                                                   write_buf);
            // Copy data returned by SPI master into buffer
            memcpy(buffer, read_buf, buffer_length);
            break;
        }
      } else { // Must be BUS_WRITE
        // Writing to the bus FROM buffer, ignore received data
        i_wifi_bcm_wiced_async_spi.init_transfer_array_8(move(read_buf),
                                                         move(write_buf),
                                                         buffer_length);
        select {
          case i_wifi_bcm_wiced_async_spi.transfer_complete():
            i_wifi_bcm_wiced_async_spi.retrieve_transfer_buffers_8(read_buf,
                                                                   write_buf);
            break;
        }
      }
      i_wifi_bcm_wiced_async_spi.end_transaction(wifi_bcm_wiced_spi_ss_deassert_ms);
      break;
    case WIFI_FAST_SPI:
      spi_fast_init(*p_wifi_bcm_wiced_spi);
      if (BUS_READ == direction) {
        // Reading from the bus TO buffer
        spi_fast(buffer_length, (char *)buffer, *p_wifi_bcm_wiced_spi, SPI_READ);
      } else {
        spi_fast(buffer_length, (char *)buffer, *p_wifi_bcm_wiced_spi, SPI_WRITE);
      }
      break;
    default:
      unreachable("Must be WIFI_SYNCHRONOUS_SPI, WIFI_ASYNCHRONOUS_SPI, or"
                  "WIFI_FAST_SPI");
      break;
  }
}

void xcore_wiced_send_pbuf_to_internal(pbuf_p p) {
  unsafe {
    xcore_wwd_pbuf_external <: p;
  }
}

unsigned xcore_get_ticks() {
  timer t;
  unsigned time;
  t :> time;
  return time;
}

/*
 * A structure for storing pbuf pointers. It is empty when head == tail.
 */
#define NUM_BUFFERS 10
typedef struct {
  pbuf_p buffers[NUM_BUFFERS];
  unsigned head;
  unsigned tail;
} buffers_t;

static void buffers_init(buffers_t &buffers) {
  buffers.head = 0;
  buffers.tail = 0;
}

static unsafe pbuf_p buffers_take(buffers_t &buffers) {
  xassert(buffers.head != buffers.tail);
  unsigned read_index = buffers.head;
  buffers.head += 1;
  if (buffers.head == NUM_BUFFERS) {
    buffers.head = 0;
  }
  return buffers.buffers[read_index];
}

static unsafe void buffers_put(buffers_t &buffers, pbuf_p p) {
  buffers.buffers[buffers.tail] = p;
  buffers.tail += 1;
  if (buffers.tail == NUM_BUFFERS) {
    buffers.tail = 0;
  }
  xassert(buffers.head != buffers.tail);
}

static int buffers_is_empty(buffers_t &buffers){
  return (buffers.head == buffers.tail);
}

// Needs to be unsafe due to input of pbuf_p from streaming channel
[[combinable]]
static unsafe void wifi_broadcom_wiced_spi_internal( // TODO: remove spi from name now?
    server interface wifi_hal_if i_hal[n_hal], size_t n_hal,
    server interface wifi_network_config_if i_conf[n_conf], size_t n_conf,
    server interface xtcp_pbuf_if i_data,
    streaming chanend c_xcore_wwd_pbuf) {

  buffers_t rx_buffers;
  buffers_init(rx_buffers);

  wiced_ssid_t ssids[] = { {6, "SSID_1"}, {6, "SSID_2"} };
  size_t num_active_networks = 2;

  while (1) {
    select {
      // WiFi HAL interface
      case i_hal[int i].init_radio():
        // Initialise driver and hardware
        debug_printf("Initialising WWD...\n");
        wwd_result_t result = wwd_management_init(WICED_COUNTRY_UNITED_KINGDOM,
                                                  NULL);
        assert(result == WWD_SUCCESS && msg("WWD initialisation failed!"));
        debug_printf("WWD initialisation complete\n");
        break;

      case i_hal[int i].get_hardware_status():
        break;

      case i_hal[int i].get_chipset_power_mode():
        break;

      case i_hal[int i].set_chipset_power_mode():
        break;

      case i_hal[int i].get_radio_tx_power():
        break;

      case i_hal[int i].set_radio_tx_power():
        break;

      case i_hal[int i].get_radio_state():
        break;

      case i_hal[int i].set_radio_state():
        break;

      case i_hal[int i].set_antenna_mode():
        break;

      case i_hal[int i].get_channel():
        break;

      case i_hal[int i].set_channel():
        break;

      // WiFi network configuration interface
      case i_conf[int i].get_mac_address(uint8_t mac_address[6]) -> wifi_res_t result:
        wiced_mac_t local_mac;
        unsafe {
          result = (wifi_res_t)xcore_wifi_get_radio_mac_address(&local_mac);
        }
        memcpy(mac_address, &local_mac, 6);
        debug_printf("WiFi MAC address: %02X:%02X:%02X:%02X:%02X:%02X\n",
                     mac_address[0], mac_address[1], mac_address[2],
                     mac_address[3], mac_address[4], mac_address[5]);
        break;

      case i_conf[int i].set_mac_address():
        break;

      case i_conf[int i].get_link_state() -> ethernet_link_state_t state:
        state = ETHERNET_LINK_UP;
        break;

      case i_conf[int i].set_link_state(ethernet_link_state_t state):
        break;

      case i_conf[int i].set_networking_mode():
        break;

      case i_conf[int i].scan_for_networks():
        debug_printf("Internal scan_for_networks\n");
        xcore_wifi_scan_networks();
        break;

      case i_conf[int i].get_num_networks() -> size_t num_networks:
        debug_printf("Internal get_num_networks\n");
        num_networks = num_active_networks;
        break;

      case i_conf[int i].get_network_ssid(size_t index) -> const wiced_ssid_t * unsafe ssid:
        if (index < num_active_networks) {
          ssid = &ssids[index];
        } else {
          ssid = NULL;
        }
        break;

      case i_conf[int i].join_network(size_t index,
                                      uint8_t security_key[key_length],
                                      size_t key_length) -> unsigned result:
        debug_printf("join_network\n");
        xassert(key_length <= WIFI_MAX_KEY_LENGTH &&
               msg("Length of security key exceeds WIFI_MAX_KEY_LENGTH"));
        uint8_t local_key[WIFI_MAX_KEY_LENGTH];
        memcpy(local_key, security_key, key_length);
        result = xcore_wifi_join_network_at_index(index, local_key, key_length);
        break;

      case i_conf[int i].leave_network(size_t index):
        break;

      // TODO: WiFi network data interface
      case i_data.receive_packet() -> pbuf_p p:
        debug_printf("Internal receive_packet\n");
        p = buffers_take(rx_buffers);
        if (!buffers_is_empty(rx_buffers)) {
          // If there are still packets to be consumed then notify client again
          i_data.packet_ready();
        }
        break;

      case i_data.send_packet(pbuf_p p):
        // Queue the packet for the WIFI to send it
        debug_printf("Internal send_packet\n");
        // Increment the reference count as LWIP assumes packets have to be
        // deleted, and so does the WIFI library
        pbuf_ref(p);
        wwd_network_send_ethernet_data(p, WWD_STA_INTERFACE);
        break;

      case c_xcore_wwd_pbuf :> pbuf_p p:
        debug_printf("Internal packet from WIFI\n");
        buffers_put(rx_buffers, p);
        i_data.packet_ready();
        break;
    }
  }
}

/**
 * Initialise the pointers and allocate the lock used for protection and channel
 * end used for notifications.
 * The channel end is then connected to itself so only one channel end is used
 * for notifications.
 */
unsafe static unsafe streaming chanend signals_init(signals_t &signals) {
  signals.head = 0;
  signals.tail = 0;
  signals.lock = hwlock_alloc();
  xassert(signals.lock && msg("No hardware locks available"));

  asm volatile ("getr %0, " QUOTE(XS1_RES_TYPE_CHANEND)
                    : "=r" (signals.notification_chanend));
  xassert(signals.notification_chanend && msg("No notification chanend available"));
  asm volatile ("setd res[%0], %0"
                    : // No dests
                    : "r" (signals.notification_chanend));

  // The channel end is returned so that it can be passed to the xcore_wwd task
  return (streaming chanend)signals.notification_chanend;
}

/**
 * Take the signal from the head pointer and move the head pointer
 */
xcore_wwd_control_signal_t signals_take(signals_t &signals) {
  hwlock_acquire(signals.lock);
  xassert(signals.head != signals.tail);
  xcore_wwd_control_signal_t return_value = signals.signals[signals.head];
  signals.head += 1;
  if (signals.head == NUM_SIGNALS) {
    signals.head = 0;
  }
  hwlock_release(signals.lock);
  return return_value;
}

/**
 * Insert the specified signal at the tail pointer and move the tail pointer.
 * The insertion only happens if the list is currently empty or the signal
 * type is different.
 * Returns whether the buffer was empty before the insertion.
 */
int signals_put(signals_t &signals, xcore_wwd_control_signal_t signal) {
  hwlock_acquire(signals.lock);
  int was_empty = (signals.head == signals.tail);
  if (signals.signals[signals.tail] != signal || was_empty) {
    signals.signals[signals.tail] = signal;
    signals.tail += 1;
    if (signals.tail == NUM_SIGNALS) {
      signals.tail = 0;
    }
  }
  xassert(signals.head != signals.tail);
  hwlock_release(signals.lock);
  return was_empty;
}

int signals_is_empty(signals_t &signals){
  return (signals.head == signals.tail);
}

void wifi_broadcom_wiced_spi(
    server interface wifi_hal_if i_hal[n_hal], size_t n_hal,
    server interface wifi_network_config_if i_conf[n_conf], size_t n_conf,
    server interface xtcp_pbuf_if i_data,
    client interface spi_master_if i_spi,
    unsigned spi_device_index,
    client interface input_gpio_if i_irq,
    client interface fs_basic_if i_fs) {

  unsafe streaming chanend notification_chanend;
  unsafe {
    notification_chanend = signals_init(signals);
  }

  streaming chan c_xcore_wwd_pbuf;

  par {
    // TODO: 'combine' wifi_broadcom_wiced_spi_internal and xcore_wwd
    // Start the interface task
    {
      unsafe {
        i_fs_global = i_fs;
        // Save the SPI bus details for use from wwd_spi functions
        wifi_spi_master_type_in_use = WIFI_SYNCHRONOUS_SPI;
        i_wifi_bcm_wiced_spi = i_spi;
        wifi_bcm_wiced_spi_device_index = spi_device_index;
        wifi_broadcom_wiced_spi_internal(i_hal, n_hal, i_conf, n_conf,
                                         i_data, c_xcore_wwd_pbuf);
      }
    }

    /* The SDK will expect to start this from the call to wwd_management_init
     * by attempting to spawn an RTOS thread. The xCORE implementation of the
     * WWD RTOS callbacks cannot do this, so the driver task is started
     * immediately and waits to be initialised.
     */
    {
      unsafe {
        xcore_wwd_pbuf_external = (unsafe streaming chanend)c_xcore_wwd_pbuf;
        xcore_wwd(i_irq, (streaming chanend)notification_chanend);
      }
    }
  }
}

void wifi_broadcom_wiced_asyc_spi(
    server interface wifi_hal_if i_hal[n_hal], size_t n_hal,
    server interface wifi_network_config_if i_conf[n_conf], size_t n_conf,
    server interface xtcp_pbuf_if i_data,
    client interface spi_master_async_if i_spi,
    unsigned spi_device_index,
    client interface input_gpio_if i_irq,
    client interface fs_basic_if i_fs) {

  unsafe streaming chanend notification_chanend;
  unsafe {
    notification_chanend = signals_init(signals);
  }

  streaming chan c_xcore_wwd_pbuf;

  par {
    // TODO: 'combine' wifi_broadcom_wiced_spi_internal and xcore_wwd
    // Start the interface task
    {
      unsafe {
        i_fs_global = i_fs;
        // Save the SPI bus details for use from wwd_spi functions
        wifi_spi_master_type_in_use = WIFI_ASYNCHRONOUS_SPI;
        i_wifi_bcm_wiced_async_spi = i_spi;
        wifi_bcm_wiced_spi_device_index = spi_device_index;
        wifi_broadcom_wiced_spi_internal(i_hal, n_hal, i_conf, n_conf,
                                         i_data, c_xcore_wwd_pbuf);
      }
    }

    /* The SDK will expect to start this from the call to wwd_management_init
     * by attempting to spawn an RTOS thread. The xCORE implementation of the
     * WWD RTOS callbacks cannot do this, so the driver task is started
     * immediately and waits to be initialised.
     */
    {
      unsafe {
        xcore_wwd_pbuf_external = (unsafe streaming chanend)c_xcore_wwd_pbuf;
        xcore_wwd(i_irq, (streaming chanend)notification_chanend);
      }
    }
  }
}

void wifi_broadcom_wiced_fast_spi(
    server interface wifi_hal_if i_hal[n_hal], size_t n_hal,
    server interface wifi_network_config_if i_conf[n_conf], size_t n_conf,
    server interface xtcp_pbuf_if i_data,
    spi_fast_ports &p_spi,
    client interface input_gpio_if i_irq,
    client interface fs_basic_if i_fs) {

  unsafe streaming chanend notification_chanend;
  unsafe {
    notification_chanend = signals_init(signals);
  }

  streaming chan c_xcore_wwd_pbuf;

  par {
    // TODO: 'combine' wifi_broadcom_wiced_spi_internal and xcore_wwd
    // Start the interface task
    {
      unsafe {
        i_fs_global = i_fs;
        // Save the SPI bus details for use from wwd_spi functions
        wifi_spi_master_type_in_use = WIFI_FAST_SPI;
        p_wifi_bcm_wiced_spi = &p_spi;
        wifi_broadcom_wiced_spi_internal(i_hal, n_hal, i_conf, n_conf,
                                         i_data, c_xcore_wwd_pbuf);
      }
    }

    /* The SDK will expect to start this from the call to wwd_management_init
     * by attempting to spawn an RTOS thread. The xCORE implementation of the
     * WWD RTOS callbacks cannot do this, so the driver task is started
     * immediately and waits to be initialised.
     */
    {
      unsafe {
        xcore_wwd_pbuf_external = (unsafe streaming chanend)c_xcore_wwd_pbuf;
        xcore_wwd(i_irq, (streaming chanend)notification_chanend);
      }
    }
  }
}
