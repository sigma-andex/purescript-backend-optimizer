import * as $runtime from "../runtime.js";
const test9 = [false, true];
const boolValues = op => [op(true)(true), op(true)(false), op(false)(true), op(false)(false)];
const test1 = [true, false, false, false];
const test2 = [true, true, true, false];
const test3 = [true, false, false, true];
const test4 = [false, true, true, false];
const test5 = [false, false, true, false];
const test6 = [false, true, false, false];
const test7 = [true, false, true, true];
const test8 = [true, true, false, true];
export {boolValues, test1, test2, test3, test4, test5, test6, test7, test8, test9};
