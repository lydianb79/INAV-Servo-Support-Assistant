#!/usr/bin/env python3
"""Reference prototype of the Servo Support engine (mirrors the Swift implementation)."""
import os, re, sys

# ---------- embedded datasheet AF tables (timer channels only) ----------
# STM32F405/407/415/417/427/429 (DS8626 Table 9), TIM1..TIM14
F405 = """
PA0:TIM2_CH1,TIM5_CH1 PA1:TIM2_CH2,TIM5_CH2 PA2:TIM2_CH3,TIM5_CH3,TIM9_CH1 PA3:TIM2_CH4,TIM5_CH4,TIM9_CH2
PA5:TIM2_CH1,TIM8_CH1N PA6:TIM3_CH1,TIM13_CH1 PA7:TIM1_CH1N,TIM3_CH2,TIM8_CH1N,TIM14_CH1
PA8:TIM1_CH1 PA9:TIM1_CH2 PA10:TIM1_CH3 PA11:TIM1_CH4 PA15:TIM2_CH1
PB0:TIM1_CH2N,TIM3_CH3,TIM8_CH2N PB1:TIM1_CH3N,TIM3_CH4,TIM8_CH3N PB3:TIM2_CH2 PB4:TIM3_CH1 PB5:TIM3_CH2
PB6:TIM4_CH1 PB7:TIM4_CH2 PB8:TIM4_CH3,TIM10_CH1 PB9:TIM4_CH4,TIM11_CH1 PB10:TIM2_CH3 PB11:TIM2_CH4
PB13:TIM1_CH1N PB14:TIM1_CH2N,TIM8_CH2N,TIM12_CH1 PB15:TIM1_CH3N,TIM8_CH3N,TIM12_CH2
PC6:TIM3_CH1,TIM8_CH1 PC7:TIM3_CH2,TIM8_CH2 PC8:TIM3_CH3,TIM8_CH3 PC9:TIM3_CH4,TIM8_CH4
PD12:TIM4_CH1 PD13:TIM4_CH2 PD14:TIM4_CH3 PD15:TIM4_CH4
PE5:TIM9_CH1 PE6:TIM9_CH2 PE8:TIM1_CH1N PE9:TIM1_CH1 PE10:TIM1_CH2N PE11:TIM1_CH2 PE12:TIM1_CH3N PE13:TIM1_CH3 PE14:TIM1_CH4
PF6:TIM10_CH1 PF7:TIM11_CH1 PF8:TIM13_CH1 PF9:TIM14_CH1
PH6:TIM12_CH1 PH9:TIM12_CH2 PH10:TIM5_CH1 PH11:TIM5_CH2 PH12:TIM5_CH3 PH13:TIM8_CH1N PH14:TIM8_CH2N PH15:TIM8_CH3N
PI0:TIM5_CH4 PI2:TIM8_CH4 PI5:TIM8_CH1 PI6:TIM8_CH2 PI7:TIM8_CH3
"""
# STM32F411xC/E (DS10314 Table 9): TIM1-5, TIM9-11 only, no PB11 on LQFP64/UFQFPN48
F411 = """
PA0:TIM2_CH1,TIM5_CH1 PA1:TIM2_CH2,TIM5_CH2 PA2:TIM2_CH3,TIM5_CH3,TIM9_CH1 PA3:TIM2_CH4,TIM5_CH4,TIM9_CH2
PA5:TIM2_CH1 PA6:TIM3_CH1 PA7:TIM1_CH1N,TIM3_CH2 PA8:TIM1_CH1 PA9:TIM1_CH2 PA10:TIM1_CH3 PA11:TIM1_CH4 PA15:TIM2_CH1
PB0:TIM1_CH2N,TIM3_CH3 PB1:TIM1_CH3N,TIM3_CH4 PB3:TIM2_CH2 PB4:TIM3_CH1 PB5:TIM3_CH2
PB6:TIM4_CH1 PB7:TIM4_CH2 PB8:TIM4_CH3,TIM10_CH1 PB9:TIM4_CH4,TIM11_CH1 PB10:TIM2_CH3
PB13:TIM1_CH1N PB14:TIM1_CH2N PB15:TIM1_CH3N
PC6:TIM3_CH1 PC7:TIM3_CH2 PC8:TIM3_CH3 PC9:TIM3_CH4
PD12:TIM4_CH1 PD13:TIM4_CH2 PD14:TIM4_CH3 PD15:TIM4_CH4
PE5:TIM9_CH1 PE6:TIM9_CH2 PE8:TIM1_CH1N PE9:TIM1_CH1 PE10:TIM1_CH2N PE11:TIM1_CH2 PE12:TIM1_CH3N PE13:TIM1_CH3 PE14:TIM1_CH4
"""

def parse_table(s):
    d = {}
    for tok in s.split():
        pin, chans = tok.split(':')
        d[pin] = chans.split(',')
    return d

FAMILIES = {
    # cmake fn -> (display, family key, timer prefix, timer_def header, timer impl, embedded table)
    'stm32f405xg': ('STM32F405', 'F4', 'TIM', 'timer_def_stm32f4xx.h', 'timer_stm32f4xx.c', F405),
    'stm32f427xg': ('STM32F427', 'F4', 'TIM', 'timer_def_stm32f4xx.h', 'timer_stm32f4xx.c', F405),
    'stm32f411xe': ('STM32F411', 'F4', 'TIM', 'timer_def_stm32f4xx.h', 'timer_stm32f4xx.c', F411),
    'stm32f722xe': ('STM32F722', 'F7', 'TIM', 'timer_def_stm32f7xx.h', 'timer_stm32f7xx.c', F405),
    'stm32f745xg': ('STM32F745', 'F7', 'TIM', 'timer_def_stm32f7xx.h', 'timer_stm32f7xx.c', F405),
    'stm32f765xg': ('STM32F765', 'F7', 'TIM', 'timer_def_stm32f7xx.h', 'timer_stm32f7xx.c', F405),
    'stm32f765xi': ('STM32F765', 'F7', 'TIM', 'timer_def_stm32f7xx.h', 'timer_stm32f7xx.c', F405),
    'stm32h743xi': ('STM32H743', 'H7', 'TIM', 'timer_def_stm32h7xx.h', 'timer_stm32h7xx.c', None),
    'at32f43x':    ('AT32F435/437', 'AT32', 'TMR', 'timer_def_at32f43x.h', 'timer_at32f43x.c', None),
}

def strip_block_comments(text):
    return re.sub(r'/\*.*?\*/', lambda m: re.sub(r'[^\n]', ' ', m.group(0)), text, flags=re.S)

def code_part(line):
    i = line.find('//')
    return line if i < 0 else line[:i]

class ChipDB:
    def __init__(self, root, fam_key):
        disp, fam, prefix, hdr, impl, embedded = FAMILIES[fam_key]
        self.display, self.family, self.prefix = disp, fam, prefix
        drv = os.path.join(root, 'src/main/drivers')
        hdr_txt = open(os.path.join(drv, hdr)).read()
        self.inav_af = {}   # pin -> set of TIMx_CHy (from inav header)
        for m in re.finditer(r'^\s*#define\s+DEF_TIM_AF__(P[A-K]\d+)__TCH_(\w+?_CH\dN?)\s+D\((\d+)\s*,\s*(\d+)\)', hdr_txt, re.M):
            self.inav_af.setdefault(m.group(1), {})[m.group(2)] = int(m.group(3))
        self.dma_btch = set(re.findall(r'^\s*#define\s+DEF_TIM_DMA__BTCH_(\w+_CH\dN?)\b', hdr_txt, re.M))
        tdef = open(os.path.join(drv, 'timer_def.h')).read()
        self.btch_alias = dict(re.findall(r'^\s*#define\s+BTCH_(\w+_CH\dN)\s+BTCH_(\w+_CH\d)\b', tdef, re.M))
        impl_txt = open(os.path.join(drv, impl)).read()
        self.timers = set(re.findall(r'\.tim\s*=\s*(' + prefix + r'\d+)', impl_txt))
        if fam_key == 'stm32f411xe':
            self.timers -= {'TIM8', 'TIM12', 'TIM13', 'TIM14'}
        self.embedded = parse_table(embedded) if embedded else None
        if self.family == 'F4':
            self.source = 'embedded datasheet table (%s)' % disp
        else:
            self.source = 'inav drivers/%s AF table' % hdr

    def btch(self, timch):
        return self.btch_alias.get(timch, timch)

    def options(self, pin):
        """returns list of (timch, usable(bool), reason)"""
        out = []
        if self.family == 'F4':
            for tc in self.embedded.get(pin, []):
                tim = tc.split('_')[0]
                if tim not in self.timers:
                    out.append((tc, False, 'timer %s not available in inav for this MCU' % tim))
                elif self.btch(tc) not in self.dma_btch:
                    out.append((tc, False, 'no DMA descriptor for %s in inav' % tc))
                else:
                    out.append((tc, True, ''))
        else:
            seen = set()
            for tc, af in sorted(self.inav_af.get(pin, {}).items()):
                seen.add(tc)
                tim = tc.split('_')[0]
                if tim not in self.timers:
                    out.append((tc, False, 'timer %s not in inav timer list' % tim))
                elif self.btch(tc) not in self.dma_btch:
                    out.append((tc, False, 'missing DEF_TIM_DMA__BTCH_%s in inav' % self.btch(tc)))
                else:
                    out.append((tc, True, 'AF%d' % af))
            if self.embedded and self.family == 'F7':
                for tc in self.embedded.get(pin, []):
                    if tc not in seen:
                        out.append((tc, False, 'datasheet lists it, but inav AF table has no DEF_TIM_AF__%s__TCH_%s' % (pin, tc)))
        return out

# ---------- target parsing ----------
DEF_TIM_RE = re.compile(r'DEF_TIM\s*\(([^)]*)\)')

class TimerEntry:
    def __init__(self, line_no, args, comment, active):
        self.line_no, self.args, self.comment, self.active = line_no, args, comment, active
        self.tim, self.ch, self.pin, self.usage = args[0], args[1], args[2], args[3]
    @property
    def timch(self): return '%s_%s' % (self.tim, self.ch)
    def has(self, flag):
        u = self.usage
        if 'TIM_USE_OUTPUT_AUTO' in u and flag in ('TIM_USE_MOTOR', 'TIM_USE_SERVO'): return True
        return flag in u

def parse_target(tdir):
    res = {'name': os.path.basename(tdir)}
    cm = open(os.path.join(tdir, 'CMakeLists.txt')).read()
    res['mcus'] = re.findall(r'target_(\w+)\s*\(\s*(\w+)', cm)
    h = open(os.path.join(tdir, 'target.h')).read()
    res['h_lines'] = h.split('\n')
    defines = {}
    for i, line in enumerate(strip_block_comments(h).split('\n')):
        m = re.match(r'\s*#\s*define\s+(\w+)(?:\s+(.*?))?\s*$', code_part(line))
        if m:
            defines.setdefault(m.group(1), []).append((i, (m.group(2) or '').strip()))
    res['defines'] = defines
    c = open(os.path.join(tdir, 'target.c')).read()
    res['c_lines'] = c.split('\n')
    entries = []
    nb = strip_block_comments(c).split('\n')
    for i, line in enumerate(nb):
        cp = code_part(line)
        m = DEF_TIM_RE.search(cp)
        active = True
        if not m:
            m2 = DEF_TIM_RE.search(line)
            if not m2: continue
            m, active = m2, False
        args = [a.strip() for a in m.group(1).split(',')]
        if len(args) < 6: continue
        cmt = line[line.find('//') + 2:].strip() if '//' in line[m.end():] else ''
        entries.append(TimerEntry(i, args, cmt, active))
    res['timers'] = entries
    return res

def def_value(t, name):
    v = t['defines'].get(name)
    return v[0][1] if v else None

PIN_RE = re.compile(r'^P[A-K]\d{1,2}$')

def analyze_pin(p, act, db, softserial_pins, softserial_timers, other_pin_users, adc_pins):
    pin = p['pin']
    p['existing'] = [e for e in act if e.pin == pin]
    opts = []
    if p['existing']:
        e = p['existing'][0]
        opts.append({'timch': e.timch, 'usable': True, 'kind': 'already servo' if e.has('TIM_USE_SERVO') else 'upgrade', 'issues': []})
    else:
        for tc, ok, why in db.options(pin):
            opts.append({'timch': tc, 'usable': ok, 'kind': 'new' if ok else 'unusable', 'issues': [] if ok else [('block', why)]})
    for o in opts:
        if not o['usable']: continue
        tim, ch = o['timch'].split('_', 1)
        same_tim = [e for e in act if e.tim == tim and e.pin != pin]
        motors = [e for e in same_tim if e.has('TIM_USE_MOTOR') and not e.has('TIM_USE_SERVO')]
        autos = [e for e in same_tim if e.has('TIM_USE_MOTOR') and e.has('TIM_USE_SERVO')]
        if motors: o['issues'].append(('block', '%s drives motor outputs (%s); motors and servos cannot share a timer' % (tim, ','.join(e.pin for e in motors))))
        if autos: o['issues'].append(('warn', '%s shared with outputs %s - they must all be servos' % (tim, ','.join(e.pin for e in autos))))
        if any(e.has('TIM_USE_LED') for e in same_tim): o['issues'].append(('warn', '%s also drives LED strip' % tim))
        if any(e.has('TIM_USE_BEEPER') for e in same_tim): o['issues'].append(('warn', '%s also drives beeper' % tim))
        if any(e.has('TIM_USE_PPM') or e.has('TIM_USE_PWM') for e in same_tim): o['issues'].append(('warn', '%s used for PPM/PWM input' % tim))
        bch = ch.rstrip('N')
        clash = [e for e in same_tim if e.ch.rstrip('N') == bch]
        if clash: o['issues'].append(('block', '%s %s already used on pin %s' % (tim, bch, clash[0].pin)))
        if tim in softserial_timers: o['issues'].append(('warn', '%s used by softserial' % tim))
        if ch.endswith('N'): o['issues'].append(('info', 'complementary (N) channel'))
        if pin in adc_pins: o['issues'].append(('block', 'pin is an ADC channel'))
        if pin in other_pin_users: o['issues'].append(('warn', 'pin also used by ' + ','.join(other_pin_users[pin])))
        if pin in softserial_pins: o['issues'].append(('warn', 'pin used by softserial'))
    sev = {'block': 3, 'warn': 1, 'info': 0}
    def score(o):
        if not o['usable']: return 1000
        s = sum(sev[k] for k, _ in o['issues']) * 10
        tim = o['timch'].split('_')[0]
        if not any(e.tim == tim for e in act): s -= 1
        return s
    opts.sort(key=score)
    p['options'] = opts
    p['best'] = opts[0] if opts and opts[0]['usable'] and not any(k == 'block' for k, _ in opts[0]['issues']) else None


def analyze(t, db):
    act = [e for e in t['timers'] if e.active]
    uarts = []
    softserial_pins = set()
    for k in ('SOFTSERIAL_1_RX_PIN', 'SOFTSERIAL_1_TX_PIN', 'SOFTSERIAL_2_RX_PIN', 'SOFTSERIAL_2_TX_PIN'):
        for _, v in t['defines'].get(k, []):
            if PIN_RE.match(v): softserial_pins.add(v)
    softserial_timers = {e.tim for e in act if e.pin in softserial_pins}
    other_pin_users = {}
    for name, vals in t['defines'].items():
        if re.match(r'UART\d+_', name) or name.startswith('SOFTSERIAL_') or name == 'WS2811_PIN': continue
        for _, v in vals:
            if PIN_RE.match(v): other_pin_users.setdefault(v, []).append(name)
    adc_pins = {v for n, vals in t['defines'].items() if n.startswith('ADC_CHANNEL_') for _, v in vals if PIN_RE.match(v)}
    rx_uart = def_value(t, 'SERIALRX_UART')
    for n in range(1, 9):
        if 'USE_UART%d' % n not in t['defines']: continue
        u = {'n': n, 'pins': [], 'notes': []}
        for role in ('TX', 'RX'):
            for _, v in t['defines'].get('UART%d_%s_PIN' % (n, role), []):
                if PIN_RE.match(v) and v not in [p['pin'] for p in u['pins']]:
                    u['pins'].append({'role': role, 'pin': v})
        if n == 1: u['notes'].append('UART1 is not covered by inav runtime pin-conflict check -> dedicated mode required')
        if rx_uart == 'SERIAL_PORT_USART%d' % n: u['notes'].append('default receiver UART')
        for p in u['pins']:
            analyze_pin(p, act, db, softserial_pins, softserial_timers, other_pin_users, adc_pins)
        u['candidate'] = any(p['best'] for p in u['pins'])
        uarts.append(u)
    led = []
    for _, v in t['defines'].get('WS2811_PIN', []):
        if PIN_RE.match(v) and v not in led: led.append(v)
    for e in act:
        if e.has('TIM_USE_LED') and e.pin not in led: led.append(e.pin)
    uart_pins = {p['pin'] for u in uarts for p in u['pins']}
    led = [x for x in led if x not in uart_pins]
    if led:
        g = {'n': 'LED', 'pins': [{'role': 'LED', 'pin': x} for x in led], 'notes': []}
        for p in g['pins']:
            analyze_pin(p, act, db, softserial_pins, softserial_timers, other_pin_users, adc_pins)
        g['candidate'] = any(p['best'] for p in g['pins'])
        uarts.append(g)
    return uarts

def summarize(root):
    tdir = os.path.join(root, 'src/main/target')
    stats = {'targets': 0, 'unsupported': 0, 'cand_uarts': 0}
    for name in sorted(os.listdir(tdir)):
        p = os.path.join(tdir, name)
        if not all(os.path.isfile(os.path.join(p, f)) for f in ('target.c', 'target.h', 'CMakeLists.txt')): continue
        t = parse_target(p)
        if not t['mcus'] or t['mcus'][0][0] not in FAMILIES:
            stats['unsupported'] += 1; continue
        db = ChipDB(root, t['mcus'][0][0])
        us = analyze(t, db)
        stats['targets'] += 1
        line = []
        for u in us:
            if u['candidate']:
                stats['cand_uarts'] += 1
                line.append('U%s[%s]' % (u['n'], ' '.join('%s=%s' % (p['pin'], p['best']['timch'] + ('' if p['best']['kind'] == 'new' else '*')) for p in u['pins'] if p['best'])))
        print('%-24s %-12s %s' % (name, db.display, ' '.join(line)))
    print(stats)


TAG = 'INAV Servo Support Assistant'

def find_close(lines):
    st = strip_block_comments('\n'.join(lines)).split('\n')
    start = next((i for i, l in enumerate(st) if 'timerHardware' in l and '[' in l and '=' in l), None)
    if start is None: return None
    depth = 0; opened = False
    for i in range(start, len(st)):
        for ch in code_part(st[i]):
            if ch == '{': depth += 1; opened = True
            if ch == '}': depth -= 1
        if opened and depth <= 0: return i
    return None

def upgrade_line(line, label, removing=()):
    m = re.search(r'DEF_TIM\s*\(([^)]*)\)', line)
    args = m.group(1).split(',')
    lead = args[3][:len(args[3]) - len(args[3].lstrip(' \t'))]
    flags = [f.strip() for f in args[3].split('|') if f.strip() and f.strip() not in ('TIM_USE_ANY', '0') and f.strip() not in removing]
    if 'TIM_USE_SERVO' not in flags and 'TIM_USE_OUTPUT_AUTO' not in flags: flags.append('TIM_USE_SERVO')
    args[3] = lead + ' | '.join(flags)
    new = line[:m.start()] + 'DEF_TIM(' + ','.join(args) + ')' + line[m.end():]
    return new + (' | %s servo (%s)' % (label, TAG) if '//' in new else ' // %s servo (%s)' % (label, TAG))

def make_plan(t, choices):
    """choices: list of (uart, role, pin, option, mode)"""
    c = list(t['c_lines']); new = []; added = 0
    for (n, role, pin, o, mode) in sorted(choices, key=lambda x: (str(x[0]), x[1])):
        label = 'LED pad %s' % pin if n == 'LED' else 'UART%d %s' % (n, role)
        if o['kind'] == 'already servo': continue
        if o['kind'] == 'upgrade':
            e = [p for p in t['timers'] if p.active and p.pin == pin][0]
            c[e.line_no] = upgrade_line(c[e.line_no], label, ('TIM_USE_LED',) if (n == 'LED' and mode == 'dedicated') else ())
            if not (e.has('TIM_USE_MOTOR') or e.has('TIM_USE_SERVO')): added += 1
        else:
            tim, ch = o['timch'].split('_', 1)
            call = 'DEF_TIM(%s, %s, %s,' % (tim, ch, pin)
            new.append('    ' + call.ljust(26) + ' TIM_USE_SERVO, 0, 0), // %s pad -> servo (%s)' % (label, TAG)); added += 1
    if new:
        cl = find_close(c)
        i = cl - 1
        while i >= 0:
            code = code_part(c[i])
            if not code.strip() or code.strip().startswith('#'): i -= 1; continue
            m = re.search(r'DEF_TIM\s*\([^)]*\)', code)
            if m and not code[m.end():].strip().startswith(','):
                c[i] = c[i][:m.end()] + ',' + c[i][m.end():]
            break
        block = ['', '    // Servo outputs on UART pads – added by ' + TAG] + new
        if cl > 0 and not c[cl - 1].strip(): block = block[1:]
        c[cl:cl] = block
    h = list(t['h_lines'])
    ded = sorted({x[0] for x in choices if x[4] == 'dedicated' and x[0] != 'LED'})
    if any(x[0] == 'LED' and x[4] == 'dedicated' and x[3]['kind'] != 'already servo' for x in choices):
        for i, l in enumerate(h):
            cp = code_part(l)
            if re.match(r'^\s*#\s*define\s+(USE_LED_STRIP\b|WS2811_\w+|LED_STRIP_TIMER\b)', cp):
                h[i] = '// ' + l + '    // disabled: pad used as servo output (%s)' % TAG
            elif re.match(r'^\s*#\s*define\s+DEFAULT_FEATURES\b', cp) and 'FEATURE_LED_STRIP' in cp:
                for pat, rp in ((r'\s*\|\s*FEATURE_LED_STRIP\b', ''), (r'\bFEATURE_LED_STRIP\s*\|\s*', ''), (r'\bFEATURE_LED_STRIP\b', '0')):
                    if re.search(pat, l): l = re.sub(pat, rp, l, count=1); break
                h[i] = l + '  // FEATURE_LED_STRIP removed (%s)' % TAG
    for n in ded:
        for i, l in enumerate(h):
            if re.match(r'^\s*#\s*define\s+(USE_UART%d\b|UART%d_\w+)' % (n, n), code_part(l)):
                h[i] = '// ' + l + '    // disabled: pads used as servo outputs (%s)' % TAG
    if ded:
        for i, l in enumerate(h):
            m = re.match(r'^(\s*#\s*define\s+SERIAL_PORT_COUNT\s+)([0-9]+)(.*)$', code_part(l))
            if m: h[i] = m.group(1) + str(max(1, int(m.group(2)) - len(ded))) + m.group(3) + '  // was %s (%s)' % (m.group(2), TAG)
    if added:
        for i, l in enumerate(h):
            m = re.match(r'^(\s*#\s*define\s+MAX_PWM_OUTPUT_PORTS\s+)([0-9]+)(.*)$', code_part(l))
            if m: h[i] = m.group(1) + str(int(m.group(2)) + added) + m.group(3) + '  // was %s (%s)' % (m.group(2), TAG)
    return '\n'.join(c), '\n'.join(h)

def patch_all(root, out, led_mode='shared'):
    import difflib
    tdir = os.path.join(root, 'src/main/target'); ok = 0; bad = []
    for name in sorted(os.listdir(tdir)):
        p = os.path.join(tdir, name)
        if not all(os.path.isfile(os.path.join(p, f)) for f in ('target.c', 'target.h', 'CMakeLists.txt')): continue
        t = parse_target(p)
        if not t['mcus'] or t['mcus'][0][0] not in FAMILIES: continue
        us = analyze(t, ChipDB(root, t['mcus'][0][0]))
        choices = []; used = set()
        for u in us:
            for pp in u['pins']:
                b = pp['best']
                if not b: continue
                key = b['timch'].rstrip('N')
                if key in used: continue
                used.add(key)
                choices.append((u['n'], pp['role'], pp['pin'], b, led_mode if u['n'] == 'LED' else ('dedicated' if u['n'] == 1 else 'shared')))
        if not choices: continue
        nc, nh = make_plan(t, choices)
        # sanity: brace balance and every DEF_TIM line in array ends with comma or is last
        body = strip_block_comments(nc)
        if body.count('{') != body.count('}') or nc.count('DEF_TIM(') != '\n'.join(t['c_lines']).count('DEF_TIM(') + sum(1 for x in choices if x[3]['kind'] == 'new'):
            bad.append(name)
        else: ok += 1
        os.makedirs(os.path.join(out, name), exist_ok=True)
        open(os.path.join(out, name, 'target.c.diff'), 'w').write(''.join(difflib.unified_diff([l + '\n' for l in t['c_lines']], [l + '\n' for l in nc.split('\n')], 'a/target.c', 'b/target.c')))
        open(os.path.join(out, name, 'target.h.diff'), 'w').write(''.join(difflib.unified_diff([l + '\n' for l in t['h_lines']], [l + '\n' for l in nh.split('\n')], 'a/target.h', 'b/target.h')))
    print('patched ok:', ok, 'suspicious:', bad)

def detail(root, name):
    p = os.path.join(root, 'src/main/target', name)
    t = parse_target(p); db = ChipDB(root, t['mcus'][0][0])
    for u in analyze(t, db):
        print('UART%s candidate=%s notes=%s' % (u['n'], u['candidate'], u['notes']))
        for pp in u['pins']:
            print('   %s %s best=%s' % (pp['role'], pp['pin'], pp['best'] and pp['best']['timch']))
            for o in pp['options']:
                print('       %-14s %-12s %s' % (o['timch'], o['kind'], o['issues']))

if __name__ == '__main__':
    if len(sys.argv) > 3 and sys.argv[2] == '--patch-all': patch_all(sys.argv[1], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else 'shared')
    elif len(sys.argv) > 2: detail(sys.argv[1], sys.argv[2])
    else: summarize(sys.argv[1])
