//! What gather and draw call that isn't ported yet (Phase 2 goes collector by collector): each
//! leaves what bash's would when it finds nothing. Removed as each collector lands.

use super::sh::Bytes;
use super::G;

impl G {
    pub fn agents_look(&mut self) {}
    pub fn wait_watch(&mut self) {}
    pub fn outside_ssh(&mut self) {
        self.x_ssh.clear();
        self.x_where.clear();
    }
    pub fn remote_panes(&mut self) {
        self.p_groups = 0;
    }
    pub fn git_info(&mut self, _d: &[u8]) -> Bytes {
        Vec::new()
    }
    pub fn peek_look(&mut self, _h: &[u8], _id: &[u8], _n: i64) -> (Bytes, Vec<Bytes>) {
        (Vec::new(), Vec::new())
    }
    pub fn intros_look(&mut self) -> Vec<Bytes> {
        Vec::new()
    }
    pub fn messages(&mut self) -> (Vec<Bytes>, i64, i64, Bytes) {
        (Vec::new(), 0, -1, b"0".to_vec())
    }
    pub fn links_saves(&mut self) -> Vec<Bytes> {
        Vec::new()
    }
}
