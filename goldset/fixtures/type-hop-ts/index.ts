class Snapshot {}
export const label: string = "x";

export function f(s: Snapshot | undefined): void {
    const _ = s;
    const l2 = label;
}

class Box {}
const b: Box | null = null;
const c = b;
