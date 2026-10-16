// s6la8 enclosure: printed tray + lid, four M3 screws into heat-set inserts.
//
// Coordinates are the KiCad board's, as exported by `kicad-cli pcb export stl`:
// x = KiCad X, y = -KiCad Y, z = 0 at the bottom of the PCB (top at 1.6).
// That lets case/check.py place the real board model inside the case and look
// for collisions.  Render one part at a time:
//
//   openscad -D 'part="tray"' -o build/tray.stl s6la8_case.scad
//   openscad -D 'part="lid"'  -o build/lid.stl  s6la8_case.scad
//
// Print: PETG or ASA, 0.2 mm layers, 4 walls, 20 % infill, no supports.
// The tray prints floor down, the lid prints top down (it is flipped for export).
// Hardware: 4x M3x12 button-head screw (ISO 7380), 4x M3 heat-set insert
// (OD 4.0-4.2 mm, length 4 mm), 4x 8 mm round rubber foot.

part = "assembly";      // tray | lid | assembly

$fn = 48;
eps = 0.01;

// board
bx0 = 99.95;  bx1 = 200.05;     // KiCad X
by0 = -124.05; by1 = -59.95;    // -KiCad Y
pcb = 1.6;
holes = [[104, -64], [196, -64], [104, -120], [196, -120]];

// case
gap = 0.4;          // board to inner wall
wall = 2.2;
floor_t = 2.0;
top_t = 2.0;
standoff = 3.5;     // under the board: through-hole leads reach 1.4 mm
headroom = 10.6;    // above the board: tallest part (J1 header) reaches 8.5 mm
corner = 3.0;

x0 = bx0 - gap - wall;  x1 = bx1 + gap + wall;
y0 = by0 - gap - wall;  y1 = by1 + gap + wall;
zb = -standoff - floor_t;           // outside bottom
zs = pcb;                           // split plane: board top surface
zt = pcb + headroom + top_t;        // outside top

// openings
usb_y = -106; usb_z = pcb + 1.65; usb_w = 12.6; usb_h = 7.0;    // plug overmold fits through
probe_y0 = -94.6; probe_y1 = -66.4; probe_z1 = pcb + 6.6;       // two rows of DuPont housings
jumpers = [ // [KiCad X0, X1, Y, label]
    [116.0, 121.08, 117.0, "VREF  TGT | 3V3"],
    [130.0, 132.54, 120.5, "MODE"]];
leds = [ // [KiCad X, Y, label]
    [190.0, 97.0, "PWR"], [158.55, 103.44, "USB"], [131.49, 87.98, "RUN"], [140.37, 100.29, "ERR"]];
probe_rows = [ // KiCad Y of each pin pair (signal row on top, ground row below), label
    [92.0, "0"], [89.46, "1"], [86.92, "2"], [84.38, "3"], [81.84, "4"],
    [79.3, "5"], [76.76, "6"], [74.22, "7"], [71.68, "VR"], [69.14, "CK"]];

module rbox(xa, ya, xb, yb, za, zz, r = corner) {
    translate([0, 0, za]) linear_extrude(zz - za)
        hull() for (x = [xa + r, xb - r], y = [ya + r, yb - r]) translate([x, y]) circle(r);
}

module shell(za, zz) {
    difference() {
        rbox(x0, y0, x1, y1, za, zz);
        rbox(x0 + wall, y0 + wall, x1 - wall, y1 - wall, za - eps, zz + eps, corner - wall + 0.5);
    }
}

module openings() {
    // USB-C, right wall
    translate([x1 - wall - 1, usb_y, usb_z]) rotate([0, 90, 0])
        linear_extrude(wall + 2) offset(r = 2) offset(delta = -2) square([usb_h, usb_w], center = true);
    // probe header bay, left wall
    translate([x0 - 1, probe_y0, zs - 0.2]) cube([wall + 2, probe_y1 - probe_y0, probe_z1 - zs + 0.2]);
    // vents along both long walls, above the board
    for (x = [124 : 6 : 184], y = [y0 - 1, y1 - wall - 1])
        translate([x, y, pcb + 3]) cube([2.2, wall + 2, 5]);
}

module tray() {
    difference() {
        union() {
            shell(zb + floor_t, zs);
            rbox(x0, y0, x1, y1, zb, zb + floor_t);
            for (h = holes) translate([h[0], h[1], zb]) cylinder(d = 7, h = -zb);
        }
        openings();
        for (h = holes) {
            translate([h[0], h[1], zb + 0.8]) cylinder(d = 4.0, h = 10);          // heat-set insert
            translate([h[0], h[1], -0.6]) cylinder(d1 = 4.0, d2 = 5.0, h = 0.6 + eps);
        }
        for (h = holes) translate([h[0] + (h[0] < 150 ? 9 : -9), h[1] + (h[1] < -90 ? 6 : -6), zb - eps])
            cylinder(d = 8.6, h = 0.8);                                            // rubber feet
        translate([(x0 + x1) / 2, (y0 + y1) / 2, zb - eps]) mirror([1, 0, 0]) linear_extrude(0.6)
            text("s6la8  rev A", size = 6, halign = "center", valign = "center", font = "Liberation Sans:style=Bold");
    }
}

module lid() {
    difference() {
        union() {
            shell(zs, zt - top_t);
            rbox(x0, y0, x1, y1, zt - top_t, zt);
            for (h = holes) translate([h[0], h[1], zs]) cylinder(d = 6.0, h = zt - zs);   // clamps the board
            for (l = leds) translate([l[0], -l[1], pcb + 1.6]) cylinder(d = 3.6, h = zt - pcb - 1.6);
            // locating lip that drops inside the tray wall
            difference() {
                rbox(x0 + wall + 0.15, y0 + wall + 0.15, x1 - wall - 0.15, y1 - wall - 0.15, zs - 2, zs + eps, 1);
                rbox(x0 + wall + 1.35, y0 + wall + 1.35, x1 - wall - 1.35, y1 - wall - 1.35, zs - 3, zs + 1, 0.5);
                translate([x1 - wall - 3, usb_y - usb_w / 2, zs - 3]) cube([4, usb_w, 4]);
                translate([x0 + wall - 1, probe_y0, zs - 3]) cube([4, probe_y1 - probe_y0, 4]);
                translate([bx0, by0, zs - 3]) cube([bx1 - bx0, by1 - by0, 4]);        // keep off the board
            }
        }
        openings();
        for (h = holes) {
            translate([h[0], h[1], zs - 3]) cylinder(d = 3.4, h = 40);
            translate([h[0], h[1], zt - 2.2]) cylinder(d = 6.2, h = 3);                // screw head
        }
        for (l = leds) translate([l[0], -l[1], pcb + 1.0]) cylinder(d = 2.2, h = 40);  // light pipe
        for (j = jumpers) {
            translate([j[0] - 1.9, -j[2] - 1.9, pcb + 1]) cube([j[1] - j[0] + 3.8, 3.8, 40]);
        }
        // engraved labels, 0.6 mm deep
        engrave() {
            for (r = probe_rows) translate([x0 + 4.5, -r[0]]) text(r[1], size = 2.2, valign = "center");
            translate([x0 + 4.5, -96.4]) text("SIG/GND", size = 1.8, valign = "center");
            translate([x0 + 4.5, -66.1]) text("TR", size = 1.8, valign = "center");
            for (l = leds) translate([l[0], -l[1] - 3.6]) text(l[2], size = 2.0, halign = "center", valign = "center");
            for (j = jumpers) translate([(j[0] + j[1]) / 2, -j[2] + 3.6]) text(j[3], size = 1.8, halign = "center", valign = "center");
            translate([156, -70]) text("s6la8", size = 9, halign = "center", valign = "center", font = "Liberation Sans:style=Bold");
            translate([156, -78.5]) text("8 CH  LOGIC ANALYZER", size = 3, halign = "center", valign = "center");
            translate([178, -112]) text("BLADE", size = 4, halign = "center", valign = "center", font = "Liberation Sans:style=Bold");
            translate([x0 + 4.5, -100.6]) text("1.65-5.5 V", size = 2.0, halign = "center", valign = "center");
        }
    }
}

module engrave() {
    translate([0, 0, zt - 0.6]) linear_extrude(1) children();
}

if (part == "tray") tray();
else if (part == "lid") translate([0, 0, zt]) mirror([0, 0, 1]) lid();      // printed top down
else if (part == "lid_in_place") lid();
else { color("dimgray") tray(); color("gray", 0.5) lid(); }
