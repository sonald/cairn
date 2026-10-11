export function model(value: string): string {
    return value
}

function hidden() {
    return "private"
}

export class Widget {
    method(label: string): string {
        return label
    }
}

export const run = (input: number) => input + 1

export { model as alias }

import { model as renamed } from "./models"
import type { TypeOnly } from "./types"
import * as all from "./all"

export { renamed } from "./barrel"
export * from "./wild"

class Store {
    load() {}
    protected save() {}
    private drop() {}
    #seal() {}
}

export interface Shape {
    area(): number
}

type Point = { x: number }

export enum Color { Red, Green }

const later = () => 0

export { later, Store as Box }
