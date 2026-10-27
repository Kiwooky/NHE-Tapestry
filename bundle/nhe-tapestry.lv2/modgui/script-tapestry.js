function (event, funcs) {
    // Tapestry face script. ES5 and small on purpose: if a face script throws,
    // mod-ui silently disables it.
    //  - LCDs: Drive / Level / Mix values and the Format name, as text in the LCD web font
    //  - red button steps Format, grey button steps Tape; the Tape labels/lights are click zones too
    //  - Drive, Level, Mix sliders: drag or press anywhere along the channel
    //  - the machine's picture follows Format
    // mod-ui doesn't echo a script's own set_port_value back, so we redraw after setting.
    var icon = event.icon;
    var d = event.data;
    var NAMES = ['STUDIO REEL', 'HOME REEL', 'WALKMAN', 'VHS', 'POCKET RECORD.', 'ANSWER MACHINE',
                 'MASTER REEL', '8-TRACK', '4-TRACK'];
    var NFORMAT = 9, NTAPE = 4;
    var CAP_TRAVEL = 207.5, CAP_HALF = 36.5, TRACK_H = 280.5;   // CSS px
    var RANGE = { drive: [-12, 18, 0.5], level: [-12, 12, 0.5], mix: [0, 100, 1] };   // min, max, step
    var DEF = { format: 2, tape: 1, drive: 0, level: 0, mix: 100 };

    function clamp01(x) { return x < 0 ? 0 : (x > 1 ? 1 : x); }
    function num(v, def) { v = parseFloat(v); return isNaN(v) ? def : v; }
    function idx(sym, n) { return Math.max(0, Math.min(n - 1, Math.round(num(d[sym], DEF[sym])))); }
    function dbText(v) { v = Math.round(v); return v > 0 ? '+' + v : '' + v; }

    function draw(sym) {
        var all = !sym;
        if (all || sym == 'format') {
            var f = idx('format', NFORMAT);
            icon.find('[tp-show="lcd-format"]').text(NAMES[f]);
            var pic = icon.find('[tp-show="picture"]');
            for (var i = 0; i < NFORMAT; i++) pic.removeClass('tp-tape-' + i);
            pic.addClass('tp-tape-' + f);
        }
        if (all || sym == 'tape') {
            var t = idx('tape', NTAPE);
            icon.find('[tp-led]').each(function () {
                var el = jQuery(this);
                if (parseInt(el.attr('tp-led'), 10) == t) el.addClass('on'); else el.removeClass('on');
            });
        }
        for (var s in RANGE) {
            if (!all && sym != s) continue;
            var r = RANGE[s], v = num(d[s], DEF[s]);
            var pos = clamp01((v - r[0]) / (r[1] - r[0]));
            icon.find('[tp-slider="' + s + '"] .tp-cap').css('top', (CAP_TRAVEL * (1 - pos)) + 'px');
            icon.find('[tp-show="lcd-' + s + '"]').text(s == 'mix' ? '' + Math.round(v) : dbText(v));
        }
    }
    function set(sym, v) {
        d[sym] = v;
        funcs.set_port_value(sym, v);
        draw(sym);
    }
    function pageY(e) {
        var o = e.originalEvent || e;
        if (o.touches && o.touches.length) return o.touches[0].pageY;
        if (o.changedTouches && o.changedTouches.length) return o.changedTouches[0].pageY;
        return e.pageY;
    }
    // act on press; ignore the emulated mouse events that follow a touch
    function press(e) {
        e.preventDefault(); e.stopPropagation();
        if (e.type == 'touchstart') { d.lastTouch = new Date().getTime(); return true; }
        return !(d.lastTouch && new Date().getTime() - d.lastTouch < 1000);
    }

    if (event.type == 'start') {
        var ports = event.ports || [];
        for (var i = 0; i < ports.length; i++) d[ports[i].symbol] = ports[i].value;
        draw();

        icon.find('[tp-step]').each(function () {
            var btn = jQuery(this), sym = btn.attr('tp-step'), n = sym == 'format' ? NFORMAT : NTAPE;
            btn.on('touchstart mousedown', function (e) {
                if (!press(e)) return;
                btn.addClass('down');
                set(sym, (idx(sym, n) + 1) % n);
            });
            btn.on('click', function (e) { e.preventDefault(); e.stopPropagation(); });
            btn.on('mouseup mouseleave touchend touchcancel', function () { btn.removeClass('down'); });
        });

        icon.find('[tp-pick]').each(function () {
            var z = jQuery(this), sym = z.attr('tp-pick'), v = parseInt(z.attr('tp-value'), 10);
            z.on('touchstart mousedown', function (e) {
                if (!press(e)) return;
                if (v != idx(sym, NTAPE)) set(sym, v);
            });
            z.on('click', function (e) { e.preventDefault(); e.stopPropagation(); });
        });

        // sliders: the cap's centre follows the pointer; the panel may be zoomed, so
        // measure the track as drawn
        icon.find('[tp-slider]').each(function () {
            var tr = jQuery(this), sym = tr.attr('tp-slider'), r = RANGE[sym];
            function apply(e) {
                var h = tr[0].getBoundingClientRect().height || TRACK_H, z = h / TRACK_H;
                var y = (pageY(e) - tr.offset().top) / z - CAP_HALF;
                var v = r[0] + (1 - clamp01(y / CAP_TRAVEL)) * (r[1] - r[0]);
                v = Math.round(v / r[2]) * r[2];
                if (v != d[sym]) set(sym, v);
            }
            // a press sets the value where you press; moving only drags once past 3 px,
            // so a slightly wobbly click or tap lands where it was aimed
            var y0 = 0, dragging = false;
            function move(e) {
                e.preventDefault();
                if (!dragging && Math.abs(pageY(e) - y0) < 3) return;
                dragging = true;
                apply(e);
            }
            function up() { jQuery(document).off('.tpdrag'); }
            tr.on('touchstart mousedown', function (e) {
                if (!press(e)) return;
                y0 = pageY(e); dragging = false;
                apply(e);
                jQuery(document).on('mousemove.tpdrag touchmove.tpdrag', move)
                                .on('mouseup.tpdrag touchend.tpdrag touchcancel.tpdrag', up);
            });
            tr.on('click', function (e) { e.preventDefault(); e.stopPropagation(); });
        });
    } else if (event.type == 'change') {
        d[event.symbol] = event.value;
        draw(event.symbol);
    }
}
