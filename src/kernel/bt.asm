; =============================================================================
;  bt.asm - Bluetooth over USB (HCI). Placeholder: the driver in progress is
;  in bt.asm.wip and l2cap.asm.wip. It claims nothing, so the radio shows up
;  unbound in 'usb'.
; =============================================================================

section .text

; bt_probe(RBX = device, RSI = interface, RDI = end) -> CF = 1 if not claimed
bt_probe:
    stc
    ret
