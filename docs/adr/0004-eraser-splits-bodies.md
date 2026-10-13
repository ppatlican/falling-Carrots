# 0004: A body the eraser leaves in pieces becomes one body per piece

Date: 2026-10-13. Status: accepted (owner decision), not implemented. Scheduled in Milestone 3, before the body brush (step 5).

## Context
The owner erased the middle of a carrot, a jelly and a cork (main.tscn's Drop buttons, right-click eraser): the two parts left kept moving as one body, linked across the gap. Shape matching fits one position and one rotation to every live member of a body id (ADR 0002 items 5 and 8), so pieces that share an id move as one rigid (or one soft) body. ADR 0002 listed this as a known limit until cutting exists, and SPEC §9 deferred "cutting and fracture" past v1.

The body brush (step 5) will let players draw bodies freehand and erase parts of them, so a body left in pieces will be common, and pieces that hang together across empty space look broken.

## Decision
1. **When the eraser leaves a body in two or more pieces, each piece becomes its own body.** A piece is a group of the body's remaining members connected through members that touch on the rest lattice. Each piece then moves, falls, floats and turns on its own, keeping the motion it had at the moment of the erase (no jump, no kick).
2. **This is part of v1 (Milestone 3)**, owner's decision, 2026-10-13: "erasing middle and seeing two parts fall separately should be added now".
3. **A cutting tool and fracture stay deferred** (SPEC §9). Only the eraser splits bodies. A later cutting tool would split bodies the same way, so the split is written as a body operation the eraser calls, not as eraser-only code.

## Consequences
- A split needs a free body id and member range per new piece (ADR 0002 items 4 and 16); the body cap (`body_cap`) and the member list can run out like any other body creation.
- Each piece needs its own rest centroid, its outline (`rest_offset.zw`, ADR 0003 item 7) worked out again, which also clears the stale-outline flag the eraser sets today (ADR 0003 item 10), and its own reference pressure and wet flag (ADR 0003 item 4).
- Contacts, the push-out and the swept contacts between bodies (ADR 0003 items 11, 13, 14) must treat pieces as separate bodies from the substep they split, and must not throw the pieces apart where they still touch along the cut.
- ADR 0002's known limit "A body erased in two stays one body until cutting exists" is retired by this ADR once implemented.

## Not decided yet (for the implementation)
- Where the split runs: on the CPU after the body-record readback that already frees fully erased bodies (`ParticleSim._free_empty_bodies`), or in a GPU pass.
- What happens to a tiny piece (one or two particles): stays a small body, or becomes loose grains of a powder, or is erased with the rest.
- What happens when no body id or member range is free: the piece stays attached, or the erase is refused.
- How an erase stroke dragged across a body over many frames is handled (a split per frame, or once per stroke).
- Which piece keeps the old id (likely the largest).
