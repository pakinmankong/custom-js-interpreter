import { createFunctions } from "./lib/functions.js";
import InterpreterService from "./lib/interpreter_service.js";
import { InterpreterError, formatInterpreterError } from "./lib/errors.js";

var interpreter: InterpreterService = new InterpreterService({
  variables: {
    CURRENT_ROWS: [0, 0],
    _SOURCE_: {
      GROUP1: {
        ddd: {
          ddd: 111,
        },
      },
    },
    _UUC_DETAIL: {
      field1: "return _UUC_DETAIL.field2 + 100",
      field2: "return 100",
    },
    _RECORDS_: {
      SUMMARY: {
        field1: "return _RECORDS_.OUTER_GROUP.A - _RECORDS_.OUTER_GROUP.B",
      },
      OUTER_GROUP: {
        columns: [
          {
            name: "A",
            formula:
              "return _RECORDS_.OUTER_GROUP.GROUP1.A + _RECORDS_.OUTER_GROUP.GROUP2.A",
          },
          {
            name: "B",
            formula: "return _RECORDS_.OUTER_GROUP.GROUP2.B",
          },
        ],
        children: {
          GROUP1: [
            {
              name: "A",
              formula: "return RECORDS.OUTER_GROUP.GROUP2.A * 1000",
            },
          ],
          GROUP2: [
            {
              name: "A",
              formula: "return RECORDS.OUTER_GROUP.GROUP1.B + 100",
            },
            {
              name: "B",
              formula: "return 500",
            },
          ],
        },
      },
    },
    _RESULTS_: {
      GROUP1: {
        columns: {
          A: "return _RESULTS_.GROUP1.B + 100",
          B: "return _RECORDS_.SUMMARY.field1",
        },
      },
    },
  },

  functions: createFunctions({ getEnv: () => interpreter.currentEnv }),
});

try {
  var result = interpreter.execute(`
        print("NUMBER:", NUMBER("10"))

        print(POWER(2, 3))

        print(EMPTY(null))

        print("SUMSQ:", SUMSQ(1, 2, 3))

        print("RANDBETWEEN:", RANDBETWEEN(1, 10))

        print("MIN:", MIN([1, 2, 3, 4, 5]))
        print("MAX:", MAX(1, 2, 3, 4, 5))
        print("ABS:", ABS(-5))
        print("SQRT:", SQRT(16))
        print("LOG:", LOG(10))
        print("LOG with base e:", LOG(10, "e"))

        print("FIXED:", 3.14559, FIXED(3.14559, 2))

        print("DECIMAL_PLACES:", DECIMAL_PLACES(3.14))

        print("ROUND:", ROUND(3.54159, 4))

        print(_SOURCE_)

        var b30 = 
        "b30"


        print("SIG:", SIG(0.000123456))

        // print(_RECORDS_)



        var data = {
          test: [
            1,
            2,
            3
          ]
        }

        for (let i = 0; i < 15; i++) {
          var test = i * 100
          print(test)
        }


        const PI = 444


        print(PI)


        const testFn = () => {
          print("test")
        }


        testFn()


       

        var n = 10
        while (n >= 0) {
          print(n)
          n--
        }

      

    `);

  console.log("result: ", result);
} catch (error) {
  if (error instanceof InterpreterError) {
    console.error(formatInterpreterError(error));
  } else {
    throw error;
  }
}
