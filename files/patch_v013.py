#!/usr/bin/env python
# Post-extract patches for klipper v0.13.0 on stock K2 firmware.
# Applied by install.sh; idempotent (K2PATCH marker).
import sys

srcdir = sys.argv[1]
p = srcdir + '/klippy/extras/lis2dw.py'
s = open(p).read()
if 'K2PATCH' not in s:
    old = '''        self.query_lis2dw_cmd = self.mcu.lookup_command(
            "query_lis2dw oid=%c rest_ticks=%u", cq=cmdqueue)
        self.ffreader.setup_query_command("query_lis2dw_status oid=%c",
                                          oid=self.oid, cq=cmdqueue)'''
    new = '''        try:  # K2PATCH: stock K2 firmware ships an older query_lis2dw signature
            self.query_lis2dw_cmd = self.mcu.lookup_command(
                "query_lis2dw oid=%c rest_ticks=%u", cq=cmdqueue)
            self.ffreader.setup_query_command("query_lis2dw_status oid=%c",
                                              oid=self.oid, cq=cmdqueue)
        except Exception:
            logging.warning(
                "lis2dw: firmware query command mismatch, accelerometer "
                "disabled (stock K2 MCU firmware)")
            self.query_lis2dw_cmd = None'''
    assert old in s, "lis2dw lookup block not found"
    s = s.replace(old, new, 1)
    old2 = "        self.query_lis2dw_cmd.send([self.oid, rest_ticks])"
    new2 = '''        if self.query_lis2dw_cmd is None:
            raise self.printer.command_error(
                "lis2dw: accelerometer not supported by stock K2 MCU "
                "firmware (update MCU firmware to use resonance tests)")
        self.query_lis2dw_cmd.send([self.oid, rest_ticks])'''
    assert old2 in s, "lis2dw send site not found"
    s = s.replace(old2, new2, 1)
    old3 = "        self.query_lis2dw_cmd.send_wait_ack([self.oid, 0])"
    new3 = '''        if self.query_lis2dw_cmd is not None:
            self.query_lis2dw_cmd.send_wait_ack([self.oid, 0])'''
    assert old3 in s, "lis2dw stop site not found"
    s = s.replace(old3, new3, 1)
    old4 = '''        self.query_lis2dw_cmd = None
        mcu.add_config_cmd("config_lis2dw oid=%d bus_oid=%d bus_oid_type=%s "
                           "lis_chip_type=%s" % (oid, self.bus.get_oid(),
                            self.bus_type, self.lis_type))
        mcu.add_config_cmd("query_lis2dw oid=%d rest_ticks=0"
                           % (oid,), on_restart=True)'''
    new4 = '''        self.query_lis2dw_cmd = None
        msgs = dict(mcu.msgparser.get_messages())
        self._k2_lis_ok = msgs.get("config_lis2dw", "") == (
            "config_lis2dw oid=%d bus_oid=%d bus_oid_type=%s lis_chip_type=%s")
        if not self._k2_lis_ok:  # K2PATCH: stock fw has an older config_lis2dw
            logging.warning(
                "lis2dw: firmware config_lis2dw mismatch, accelerometer "
                "disabled (stock K2 MCU firmware)")
        else:
            mcu.add_config_cmd("config_lis2dw oid=%d bus_oid=%d bus_oid_type=%s "
                               "lis_chip_type=%s" % (oid, self.bus.get_oid(),
                                self.bus_type, self.lis_type))
            mcu.add_config_cmd("query_lis2dw oid=%d rest_ticks=0"
                               % (oid,), on_restart=True)'''
    assert old4 in s, "lis2dw config cmd block not found"
    s = s.replace(old4, new4, 1)
    old5 = '''    def _build_config(self):
        cmdqueue = self.bus.get_command_queue()'''
    new5 = '''    def _build_config(self):
        if not getattr(self, "_k2_lis_ok", False):
            return
        cmdqueue = self.bus.get_command_queue()'''
    assert old5 in s, "lis2dw _build_config head not found"
    s = s.replace(old5, new5, 1)
    open(p, 'w').write(s)
    print("lis2dw.py patched (accelerometer graceful-degrade)")
else:
    print("lis2dw.py already patched")
