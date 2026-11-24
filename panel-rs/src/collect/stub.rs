//! What gather and draw call that isn't ported yet (Phase 2 goes collector by collector): each
//! leaves what bash's would when it finds nothing. Removed as each collector lands.

use super::sh::Bytes;
use super::G;

impl G {
    pub fn remote_panes(&mut self) {
        self.p_groups = 0;
    }
    pub fn peek_look(&mut self, _h: &[u8], _id: &[u8], _n: i64) -> (Bytes, Vec<Bytes>) {
        (Vec::new(), Vec::new())
    }
}
