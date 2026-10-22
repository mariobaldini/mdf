//! Scale preference and fallback rules without platform objects.
pub const Policy = struct {
    fractional: u32 = 0,
    preferred: u32 = 0,
    output: u32 = 1,
    viewport: bool = false,
    buffer_scale: bool = true,
    pub fn units(self: Policy) u32 {
        if (self.viewport and self.fractional > 0 and self.fractional <= 960) return self.fractional;
        if (!self.viewport and !self.buffer_scale) return 120;
        const integer = if (self.preferred > 0 and self.preferred <= 8) self.preferred else self.output;
        return if (integer > 0 and integer <= 8) integer * 120 else 120;
    }
    pub fn cursorScale(self: Policy) u32 {
        return @max(1, (self.units() + 119) / 120);
    }
};
