"""
Self-checking cocotb testbench for mac_int8.

The DUT's pipeline depth is chosen at elaboration time via the
PIPE_STAGES parameter, and the Makefile builds every depth in turn
(make all-depths), so the same tests run against all four
configurations.

Checks:
  * exhaustive: all 65536 signed 8x8 products
  * randomized MAC streams against a Python reference accumulator
  * corner operands (-128 in particular, where negating overflows 8 bits)
  * back-pressure-free streaming with in_valid gaps
  * accumulator clear behaviour
  * latency matches PIPE_STAGES + 1
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

PIPE_STAGES = int(os.environ.get("PIPE_STAGES", "3"))
LATENCY = PIPE_STAGES + 1
ACC_W = 32
ACC_MASK = (1 << ACC_W) - 1


def to_signed(value, bits):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def to_unsigned(value, bits):
    return value & ((1 << bits) - 1)


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.in_valid.value = 0
    dut.acc_clear.value = 0
    dut.a.value = 0
    dut.b.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def drive(dut, a, b, clear=0):
    """Present one operand pair for a single cycle."""
    dut.a.value = to_unsigned(a, 8)
    dut.b.value = to_unsigned(b, 8)
    dut.acc_clear.value = clear
    dut.in_valid.value = 1
    await RisingEdge(dut.clk)
    dut.in_valid.value = 0
    dut.acc_clear.value = 0


class ResultMonitor:
    """Records every cycle where out_valid is high."""

    def __init__(self, dut):
        self.dut = dut
        self.results = []      # (product, acc)
        self._next = 0

    def start(self):
        cocotb.start_soon(self._run())
        return self

    async def _run(self):
        while True:
            await FallingEdge(self.dut.clk)
            if self.dut.out_valid.value == 1:
                self.results.append((
                    to_signed(int(self.dut.product.value), 16),
                    to_signed(int(self.dut.acc.value), ACC_W),
                ))

    async def next_result(self, limit=2000):
        for _ in range(limit):
            if self._next < len(self.results):
                r = self.results[self._next]
                self._next += 1
                return r
            await FallingEdge(self.dut.clk)
        raise TimeoutError("no result produced")


@cocotb.test()
async def test_exhaustive_products(dut):
    """Every signed 8x8 product: 65536 cases, streamed back to back."""
    await setup(dut)
    mon = ResultMonitor(dut).start()

    pairs = [(a, b) for a in range(-128, 128) for b in range(-128, 128)]

    async def feeder():
        for a, b in pairs:
            await drive(dut, a, b, clear=1)   # clear so acc == product

    cocotb.start_soon(feeder())

    for a, b in pairs:
        prod, acc = await mon.next_result()
        assert prod == a * b, f"{a} * {b} = {a*b}, got {prod}"
        assert acc == a * b, f"acc for {a}*{b}: expected {a*b}, got {acc}"

    dut._log.info(f"exhaustive: {len(pairs)} products verified "
                  f"at PIPE_STAGES={PIPE_STAGES}")


@cocotb.test()
async def test_random_mac_stream(dut):
    """Randomized MAC stream checked against a Python accumulator."""
    await setup(dut)
    mon = ResultMonitor(dut).start()
    random.seed(0xC0FFEE + PIPE_STAGES)

    vectors = [(random.randint(-128, 127), random.randint(-128, 127))
               for _ in range(500)]

    async def feeder():
        first = True
        for a, b in vectors:
            await drive(dut, a, b, clear=1 if first else 0)
            first = False

    cocotb.start_soon(feeder())

    expected_acc = 0
    for i, (a, b) in enumerate(vectors):
        prod, acc = await mon.next_result()
        expected_acc = a * b if i == 0 else expected_acc + a * b
        assert prod == a * b, f"product {a}*{b}: expected {a*b}, got {prod}"
        assert acc == expected_acc, (
            f"after {i+1} MACs: expected acc {expected_acc}, got {acc}")


@cocotb.test()
async def test_corner_operands(dut):
    """-128 is the interesting one: its negation overflows 8 bits, which
    is exactly where a careless Booth encoder breaks."""
    await setup(dut)
    mon = ResultMonitor(dut).start()

    corners = [-128, -127, -1, 0, 1, 127]
    pairs = [(a, b) for a in corners for b in corners]

    async def feeder():
        for a, b in pairs:
            await drive(dut, a, b, clear=1)

    cocotb.start_soon(feeder())

    for a, b in pairs:
        prod, _ = await mon.next_result()
        assert prod == a * b, f"corner {a} * {b}: expected {a*b}, got {prod}"


@cocotb.test()
async def test_valid_gaps(dut):
    """Idle cycles between operands must not disturb the accumulator."""
    await setup(dut)
    mon = ResultMonitor(dut).start()
    random.seed(1234)

    vectors = [(random.randint(-128, 127), random.randint(-128, 127))
               for _ in range(40)]

    async def feeder():
        first = True
        for a, b in vectors:
            await drive(dut, a, b, clear=1 if first else 0)
            first = False
            for _ in range(random.randint(0, 4)):   # random idle gap
                await RisingEdge(dut.clk)

    cocotb.start_soon(feeder())

    expected = 0
    for i, (a, b) in enumerate(vectors):
        prod, acc = await mon.next_result()
        expected = a * b if i == 0 else expected + a * b
        assert prod == a * b
        assert acc == expected, f"gap test {i}: expected {expected}, got {acc}"


@cocotb.test()
async def test_accumulator_clear(dut):
    """acc_clear must replace the accumulator rather than add to it."""
    await setup(dut)
    mon = ResultMonitor(dut).start()

    async def feeder():
        await drive(dut, 10, 10, clear=1)     # acc = 100
        await drive(dut, 5, 5)                # acc = 125
        await drive(dut, 3, 3, clear=1)       # acc = 9  (cleared)
        await drive(dut, 2, 2)                # acc = 13

    cocotb.start_soon(feeder())

    for expected_acc in (100, 125, 9, 13):
        _, acc = await mon.next_result()
        assert acc == expected_acc, f"expected acc {expected_acc}, got {acc}"


@cocotb.test()
async def test_latency_matches_pipeline_depth(dut):
    """Latency from in_valid to out_valid must be PIPE_STAGES + 1."""
    await setup(dut)

    dut.a.value = to_unsigned(7, 8)
    dut.b.value = to_unsigned(9, 8)
    dut.acc_clear.value = 1
    dut.in_valid.value = 1
    await RisingEdge(dut.clk)
    dut.in_valid.value = 0
    dut.acc_clear.value = 0

    cycles = 0
    for _ in range(20):
        await FallingEdge(dut.clk)
        cycles += 1
        if dut.out_valid.value == 1:
            break
    else:
        raise TimeoutError("out_valid never asserted")

    assert cycles == LATENCY, (
        f"PIPE_STAGES={PIPE_STAGES}: expected latency {LATENCY}, got {cycles}")
    assert to_signed(int(dut.acc.value), ACC_W) == 63
