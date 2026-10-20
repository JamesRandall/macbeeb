// Swift-facing API for the vendored perfect6502 simulation.

#include "include/Perfect6502.h"

#include "types.h"
#include "netlist_sim.h"
#include "perfect6502.h"

// Node numbers, from netlist_6502.h. (It can't be included here: it defines
// the whole netlist.)
enum {
    NODE_IRQ = 103,
    NODE_NMI = 1297,
    NODE_CLK0 = 1171,
    NODE_RW = 1156,
    NODE_SYNC = 539,
};

extern uint8_t readSP(void *state);
extern uint8_t readP(void *state);

void *p6502_create(void) { return initAndResetChip(); }
void p6502_destroy(void *chip) { destroyChip(chip); }
void p6502_half_step(void *chip) { step(chip); }
uint8_t *p6502_memory(void) { return memory; }

bool p6502_clk0(void *chip) { return isNodeHigh(chip, NODE_CLK0); }
bool p6502_rw(void *chip) { return isNodeHigh(chip, NODE_RW); }
bool p6502_sync(void *chip) { return isNodeHigh(chip, NODE_SYNC); }
uint16_t p6502_address_bus(void *chip) { return readAddressBus(chip); }
uint8_t p6502_data_bus(void *chip) { return readDataBus(chip); }
uint16_t p6502_pc(void *chip) { return readPC(chip); }
uint8_t p6502_a(void *chip) { return readA(chip); }
uint8_t p6502_x(void *chip) { return readX(chip); }
uint8_t p6502_y(void *chip) { return readY(chip); }
uint8_t p6502_sp(void *chip) { return readSP(chip); }
uint8_t p6502_p(void *chip) { return readP(chip); }
uint8_t p6502_ir(void *chip) { return readIR(chip); }

void p6502_set_irq(void *chip, bool level) { setNode(chip, NODE_IRQ, level); }
void p6502_set_nmi(void *chip, bool level) { setNode(chip, NODE_NMI, level); }
