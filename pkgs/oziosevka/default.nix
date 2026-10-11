{ pkgs, ... }:

pkgs.iosevka.override {
  set = "Oziosevka";
  privateBuildPlan = ''
    [buildPlans.IosevkaOziosevka]
    family = "Oziosevka"
    spacing = "fixed"
    serifs = "sans"
    noCvSs = true
    exportGlyphNames = true

    [buildPlans.IosevkaOziosevka.variants.design]
    one = "no-base"
    two = "straight-neck-serifless"
    five = "oblique-arched-serifless"
    six = "open-contour"
    seven = "curly-serifless"
    eight = "two-circles"
    nine = "open-contour"
    zero = "oval-unslashed"
    capital-d = "more-rounded-serifless"
    capital-g = "toothless-rounded-serifless-hooked"
    capital-m = "flat-bottom-serifless"
    capital-w = "straight-flat-top-serifless"
    a = "single-storey-serifless"
    f = "flat-hook-serifless"
    g = "single-storey-serifless"
    i = "hooky"
    j = "flat-hook-serifed"
    l = "serifed-flat-tailed"
    r = "hookless-serifless"
    t = "flat-hook-short-neck"
    w = "straight-flat-top-serifless"
    y = "straight-turn-serifless"
    capital-eszet = "rounded-serifless"
    long-s = "bent-hook-middle-serifed"
    eszet = "longs-s-lig-serifless"
    lower-delta = "flat-top"
    lower-eta = "motion-serifed"
    lower-kappa = "straight-top-right-serifed"
    lower-lambda = "straight-turn"
    lower-tau = "tailed"
    lower-upsilon = "casual-serifed"
    lower-chi = "semi-chancery-straight-serifless"
    partial-derivative = "closed-contour"
    cyrl-capital-u = "straight-turn-serifless"
    cyrl-u = "straight-turn-serifless"
    cyrl-capital-ya = "straight-motion-serifed"
    cyrl-ya = "straight-motion-serifed"
    asterisk = "penta-low"
    underscore = "above-baseline"
    caret = "low"
    ascii-single-quote = "raised-comma"
    brace = "curly-flat-boundary"
    guillemet = "straight"
    at = "fourfold"
    dollar = "open-cap"
    cent = "through-cap"
    percent = "rings-continuous-slash"
    bar = "force-upright"
    pilcrow = "low"
    micro-sign = "tailed-serifless"

    [buildPlans.IosevkaOziosevka.weights.Regular]
    shape = 400
    menu = 400
    css = 400

    [buildPlans.IosevkaOziosevka.weights.Bold]
    shape = 700
    menu = 700
    css = 700

    [buildPlans.IosevkaOziosevka.weights.Light]
    shape = 300
    menu = 300
    css = 300

    [buildPlans.IosevkaOziosevka.weights.Medium]
    shape = 500
    menu = 500
    css = 500

    [buildPlans.IosevkaOziosevka.weights.SemiBold]
    shape = 600
    menu = 600
    css = 600

    [buildPlans.IosevkaOziosevka.weights.ExtraBold]
    shape = 800
    menu = 800
    css = 800

    [buildPlans.IosevkaOziosevka.widths.Normal]
    shape = 500
    menu = 5
    css = "normal"

    [buildPlans.IosevkaOziosevka.slopes.Upright]
    angle = 0
    shape = "upright"
    menu = "upright"
    css = "normal"

    [buildPlans.IosevkaOziosevka.slopes.Italic]
    angle = 9.4
    shape = "italic"
    menu = "italic"
    css = "italic"

    [buildPlans.IosevkaOziosevka.metricOverride]
    parenSize = 852
    periodSize = 'blend(weight, [300, 90], [400, 120], [500, 150], [600, 180], [700, 210], [800, 240])'
  '';
}
