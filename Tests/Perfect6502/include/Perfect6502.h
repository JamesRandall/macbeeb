// Swift-facing API for the vendored perfect6502 simulation.

#ifndef PERFECT6502_SHIM_H
#define PERFECT6502_SHIM_H

#include <stdint.h>
#include <stdbool.h>

/// Creates a chip and holds RESET for 8 cycles. The simulation is not
/// thread-safe: memory is global, so use one chip at a time.
void *p6502_create(void);
void p6502_destroy(void *chip);

/// Toggles the clock (one half-cycle), performing the memory access on the
/// falling edge as perfect6502 does.
void p6502_half_step(void *chip);

uint8_t *p6502_memory(void);

bool p6502_clk0(void *chip);
bool p6502_rw(void *chip);
bool p6502_sync(void *chip);
uint16_t p6502_address_bus(void *chip);
uint8_t p6502_data_bus(void *chip);
uint16_t p6502_pc(void *chip);
uint8_t p6502_a(void *chip);
uint8_t p6502_x(void *chip);
uint8_t p6502_y(void *chip);
uint8_t p6502_sp(void *chip);
uint8_t p6502_p(void *chip);
uint8_t p6502_ir(void *chip);

/// Sets the IRQ or NMI pin level (active low).
void p6502_set_irq(void *chip, bool level);
void p6502_set_nmi(void *chip, bool level);

#endif
