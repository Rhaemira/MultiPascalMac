// Created by Amirali Yazdani on 10/16/26.
import XCTest
@testable import MPWinCore

final class MPWinCoreTests: XCTestCase {
    private func compile(_ source: String) throws -> CompiledProgram {
        var parser = try Parser(source: source)
        let unit = try parser.parseProgram()
        return try Loader.load(unit)
    }

    private func run(_ source: String, input: String? = nil) throws -> Machine {
        let program = try compile(source)
        let machine = Machine(program: program, options: ProgramOptions(timing: .free, input: input))
        machine.start()
        let outcome = machine.run()
        XCTAssertEqual(outcome, .completed, "Outcome: \(outcome)")
        return machine
    }


    func testPascalConstTypeSharedParameterlessProcedureAndForallSynchronization() throws {
        let machine = try run("""
        program RankSortParallel;

        const
          N = 8;

        type
          ArrType = array[1..N] of Integer;

        shared
          A, Sorted: ArrType;
          rank: array[1..N] of Integer;

        procedure RankSortPar;
        var
          i, j: Integer;
        begin
          forall i := 1 to N do
          begin
            rank[i] := 1;
            forall j := 1 to N do
            begin
              if (A[j] < A[i]) or ((A[j] = A[i]) and (j < i)) then
                rank[i] := rank[i] + 1;
            end;
          end;

          forall i := 1 to N do
            Sorted[rank[i]] := A[i];
        end;

        var
          i: Integer;
        begin
          A[1] := 5; A[2] := 2; A[3] := 8; A[4] := 1;
          A[5] := 9; A[6] := 3; A[7] := 7; A[8] := 4;
          RankSortPar;
          for i := 1 to N do Write(Sorted[i], ' ');
          WriteLn;
        end.
        """, input: nil)
        XCTAssertEqual(machine.output, "1 2 3 4 5 7 8 9 \n")
    }



    func testProcessorActivityTraceCapturesInstructionAndSwitchOverhead() throws {
        let program = try compile("""
        program ActivityTrace;
        Architecture Shared(2);
        var i, value: Integer;
        begin
          forall i := 1 to 4 do value := i * 2;
          writeln(value);
        end.
        """)
        let machine = Machine(program: program, options: ProgramOptions())
        machine.start()
        XCTAssertEqual(machine.run(), .completed)
        XCTAssertFalse(machine.processorActivity.isEmpty)
        XCTAssertTrue(machine.processorActivity.contains { $0.kind == .instruction && $0.line > 0 })
        XCTAssertTrue(machine.processorActivity.contains { $0.kind == .contextSwitch && $0.duration > 0 })
        XCTAssertTrue(machine.processorActivity.allSatisfy { $0.processor >= 0 && $0.processor < machine.availableProcessors })
        for event in machine.processorActivity {
            XCTAssertLessThanOrEqual(event.endTime, machine.processorBusyTime[event.processor])
        }
        XCTAssertEqual(machine.metrics.parallelTime, machine.processorBusyTime.max() ?? 0)
    }

    func testMissingSemicolonBetweenStatementsIsSyntaxError() throws {
        XCTAssertThrowsError(try compile("""
        program MissingSeparator;
        var value: Integer;
        begin
          value := 1
          writeln(value);
        end.
        """)) { error in
            XCTAssertTrue(String(describing: error).contains("semicolon"), "Unexpected diagnostic: \(error)")
        }
    }


    func testMissingSemicolonAfterVariableDeclarationIsSyntaxError() throws {
        XCTAssertThrowsError(try compile("""
        program MissingVarSemicolon;
        var value: Integer
        begin
          value := 1;
        end.
        """)) { error in
            XCTAssertTrue(String(describing: error).contains("semicolon"), "Unexpected diagnostic: \(error)")
        }
    }

    func testMissingSemicolonAfterConstantDeclarationIsSyntaxError() throws {
        XCTAssertThrowsError(try compile("""
        program MissingConstSemicolon;
        const VALUE = 7
        begin
          writeln(VALUE);
        end.
        """)) { error in
            XCTAssertTrue(String(describing: error).contains("semicolon"), "Unexpected diagnostic: \(error)")
        }
    }

    func testMissingProgramTerminatingPeriodIsSyntaxError() throws {
        XCTAssertThrowsError(try compile("""
        program MissingPeriod;
        begin
          writeln('hello');
        end
        """)) { error in
            XCTAssertTrue(String(describing: error).contains("period"), "Unexpected diagnostic: \(error)")
        }
    }

    func testMissingSeparatorBetweenCaseArmsIsSyntaxError() throws {
        XCTAssertThrowsError(try compile("""
        program MissingCaseSeparator;
        var choice, value: Integer;
        begin
          choice := 1;
          case choice of
            1: value := 10
            2: value := 20;
          end;
        end.
        """)) { error in
            XCTAssertTrue(String(describing: error).contains("semicolon"), "Unexpected diagnostic: \(error)")
        }
    }

    func testBasicProgramAndVarDeclaration() throws {
        let machine = try run("""
        program Test;
        var x: Integer;
        begin
          x := 2 + 3 * 4;
          writeln(x);
        end.
        """)
        XCTAssertEqual(machine.output, "14\n")
    }

    func testForLoop() throws {
        let machine = try run("""
        program Test;
        var x, sum: Integer;
        begin
          sum := 0;
          for x := 1 to 5 do sum += x;
          writeln(sum);
        end.
        """)
        XCTAssertEqual(machine.output, "15\n")
    }

    func testCharacterLiteralsOrdinalBuiltinsAndOrdinalForLoops() throws {
        let machine = try run("""
        program Ordinals;
        var ch: Char;
        var flag: Boolean;
        begin
          ch := 'A';
          writeln(ch, ' ', ord(ch), ' ', ord('A'), ' ', succ(ch), ' ', pred(succ(ch)));
          for ch := 'A' to 'C' do write(ch);
          writeln;
          for flag := false to true do writeln(flag);
        end.
        """)
        XCTAssertEqual(machine.output, "A 65 65 B A\nABC\nFALSE\nTRUE\n")
    }

    func testForLoopRejectsUndeclaredVariable() throws {
        XCTAssertThrowsError(try compile("""
        program MissingLoopVariable;
        begin
          for i := 1 to 3 do writeln(i);
        end.
        """)) { error in
            XCTAssertTrue(String(describing: error).contains("Error in Variable Name"))
        }
    }

    func testForLoopRejectsNonOrdinalVariableType() throws {
        XCTAssertThrowsError(try compile("""
        program RealLoopVariable;
        var r: Real;
        begin
          for r := 1 to 3 do writeln(r);
        end.
        """)) { error in
            XCTAssertTrue(String(describing: error).contains("FOR loop variable must have an ordinal type"))
        }
    }

    func testOrdinalForLoopDoesNotStepPastTerminalInteger() throws {
        let machine = try run("""
        program Terminal;
        var i: Integer;
        begin
          for i := 9223372036854775806 to 9223372036854775807 do write(i, ' ');
          writeln;
        end.
        """)
        XCTAssertEqual(machine.output, "9223372036854775806 9223372036854775807 \n")
    }

    func testLongConstantLiteralCanBeWrittenWithoutCrashing() throws {
        let machine = try run("""
        program TextConstant;
        const greeting = 'Hello from Multi-Pascal';
        begin
          writeln(greeting);
        end.
        """)
        XCTAssertEqual(machine.output, "Hello from Multi-Pascal\n")
    }

    func testInvalidNumericBuiltinArgumentProducesDiagnosticInsteadOfZero() throws {
        let program = try compile("""
        program InvalidBuiltin;
        var value: Integer;
        begin
          value := abs(true);
        end.
        """)
        let machine = Machine(program: program, options: ProgramOptions(timing: .free))
        machine.start()
        let outcome = machine.run()
        XCTAssertNotEqual(outcome, .completed)
        XCTAssertTrue(String(describing: outcome).contains("ABS requires an integer or real expression"))
    }

    func testUnsupportedWithStatementIsRejectedInsteadOfMiscompiled() throws {
        XCTAssertThrowsError(try compile("""
        program UnsupportedWith;
        begin
          with missingRecord do writeln(1);
        end.
        """)) { error in
            XCTAssertTrue(String(describing: error).contains("WITH statements are not supported"))
        }
    }

    func testOrdinalCharacterUnderflowIsDiagnosticNotHostOverflow() throws {
        let program = try compile("""
        program InvalidOrdinal;
        var value: Char;
        begin
          value := pred(chr(0));
        end.
        """)
        let machine = Machine(program: program, options: ProgramOptions(timing: .free))
        machine.start()
        let outcome = machine.run()
        XCTAssertNotEqual(outcome, .completed)
        XCTAssertTrue(String(describing: outcome).contains("Ordinal character is out of range"))
    }

    func testFunction() throws {
        let source = """
        program Test;
        function DoubleIt(x: Integer): Integer;
        begin
          DoubleIt := x * 2;
        end;
        var result: Integer;
        begin
          result := DoubleIt(21);
          writeln(result);
        end.
        """
        let program = try compile(source)
        let machine = Machine(program: program, options: ProgramOptions(timing: .free))
        machine.start()
        let outcome = machine.run()
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(machine.output, "42\n")
    }

    func testForallAndJoin() throws {
        let machine = try run("""
        program Test;
        var a: array [1..4] of Integer;
        var i: Integer;
        begin
          forall i := 1 to 4 do a[i] := i * 10;
          join;
          writeln(a[1], ' ', a[4]);
        end.
        """)
        XCTAssertEqual(machine.output, "10 40\n")
    }

    func testChannel() throws {
        let machine = try run("""
        program Test;
        var c: Channel of Integer;
        var x: Integer;
        begin
          fork c := 7;
          x := c;
          writeln(x);
          join;
        end.
        """)
        XCTAssertEqual(machine.output, "7\n")
    }

    func testArrayIndex() throws {
        let machine = try run("""
        program Test;
        var a: array [1..4] of Integer;
        begin
          a[1] := 10;
          a[4] := 40;
          writeln(a[1]);
          writeln(a[4]);
        end.
        """)
        XCTAssertEqual(machine.output, "10\n40\n")
    }

    func testSequentialChannel() throws {
        let machine = try run("""
        program Test;
        var c: Channel of Integer;
        var x: Integer;
        begin
          c := 7;
          x := c;
          writeln(x);
        end.
        """)
        XCTAssertEqual(machine.output, "7\n")
    }

    func testBlockComment() throws {
        let machine = try run("""
        program Test;
        var x: Integer;
        begin
          (* a comment *)
          x := 9;
          writeln(x);
        end.
        """)
        XCTAssertEqual(machine.output, "9\n")
    }
    func testWriteMultipleItems() throws {
        let machine = try run("""
        program Test;
        begin
          writeln(1, ' ', 2);
        end.
        """)
        XCTAssertEqual(machine.output, "1 2\n")
    }

    func testSelfAndMyID() throws {
        let machine = try run("""
        program Test;
        begin
          writeln(%self, ' ', %myid);
          fork writeln(%self, ' ', %myid);
          join;
        end.
        """)
        XCTAssertEqual(machine.output, "0 0\n1 1\n")
    }

    func testChannelQuestion() throws {
        let machine = try run("""
        program Test;
        var c: Channel of Integer;
        begin
          c := 7;
          if c? then writeln(1) else writeln(0);
        end.
        """)
        XCTAssertEqual(machine.output, "1\n")
    }

    func testDurationAndClock() throws {
        let machine = try run("""
        program Test;
        begin
          duration(4);
          writeln(clock);
        end.
        """)
        XCTAssertEqual(machine.output, "4\n")
    }

    func testGroupedForall() throws {
        let machine = try run("""
        program Test;
        var a: array [1..6] of Integer;
        var i: Integer;
        begin
          forall i := 1 to 6 grouping 2 do a[i] := i * 10;
          join;
          writeln(a[1], ' ', a[6]);
        end.
        """)
        XCTAssertEqual(machine.output, "10 60\n")
        XCTAssertEqual(Set(machine.status.map(\.processor)), [0, 1, 2, 3])
    }

    func testExplicitProcessorAndPortPrefix() throws {
        let machine = try run("""
        program Test;
        var c: Channel of Integer;
        begin
          fork (@3 Port c) c := 9;
          join;
          writeln(c);
        end.
        """)
        XCTAssertEqual(machine.output, "9\n")
        XCTAssertTrue(machine.processes.count >= 2)
        XCTAssertEqual(machine.processes[1].processor, 3)
    }

    func testStatementBlockLocalDeclarations() throws {
        let machine = try run("""
        program Test;
        var result: Integer;
        begin
          var local: Integer;
          begin
            local := 9;
            result := local + 1;
          end;
          writeln(result);
        end.
        """)
        XCTAssertEqual(machine.output, "10\n")
    }

    func testPointer() throws {
        let machine = try run("""
        program Test;
        var p: ^Integer;
        begin
          new(p);
          p^ := 7;
          writeln(p^);
          dispose(p);
        end.
        """)
        XCTAssertEqual(machine.output, "7\n")
    }

    func testOversizedPointerIndexBecomesDiagnosticBeforeAllocation() throws {
        let program = try compile("""
        program PointerBounds;
        var p: ^Integer;
        begin
          new(p);
          p[1000000] := 9;
        end.
        """)
        let machine = Machine(program: program, options: ProgramOptions(timing: .free))
        machine.start()
        let outcome = machine.run()
        XCTAssertNotEqual(outcome, .completed)
        XCTAssertTrue(String(describing: outcome).contains("Pointer index is outside the supported memory safety limit"))
    }

    func testLocalArrayBlock() throws {
        let machine = try run("""
        program Test;
        procedure Local();
        var a: array [1..2] of Integer;
        begin
          a[1] := 11;
          a[2] := 22;
          writeln(a[1], ' ', a[2]);
        end;
        begin
          Local();
        end.
        """)
        XCTAssertEqual(machine.output, "11 22\n")
    }


    func testForallProcessorExpressionUsesIndex() throws {
        let machine = try run("""
        program Test;
        Architecture Shared(4);
        var a: array [0..3] of Integer;
        var i: Integer;
        begin
          forall i := 0 to 3 do (@i) a[i] := %self;
          join;
          writeln(a[0], ' ', a[3]);
        end.
        """)
        XCTAssertEqual(machine.output, "0 3\n")
        XCTAssertEqual(machine.processes.filter { $0.id > 0 }.map(\.processor).sorted(), [0, 1, 2, 3])
    }

    func testReadInput() throws {
        let machine = try run("""
        program Test;
        var x: Integer;
        begin
          readln(x);
          writeln(x * 2);
        end.
        """, input: "21\n")
        XCTAssertEqual(machine.output, "42\n")
    }

    func testTimeLimitAndInvalidProcessor() throws {
        let program = try compile("""
        program Test;
        begin
          duration(20);
          writeln(1);
        end.
        """)
        let limited = Machine(program: program, options: ProgramOptions(timing: .free, timeLimit: 1))
        limited.start()
        XCTAssertEqual(limited.run(), .timeLimitExceeded)

        let invalidProgram = try compile("""
        program Test;
        Architecture Shared(2);
        begin
          fork (@5) writeln(1);
          join;
        end.
        """)
        let invalid = Machine(program: invalidProgram, options: ProgramOptions(timing: .free))
        invalid.start()
        XCTAssertEqual(invalid.run(), .runtimeError("Runtime error: INVALID PROCESSOR NUMBER"))
    }


    func testParallelElapsedTimeUsesProcessorConcurrency() throws {
        let program = try compile("""
        program Test;
        Architecture Shared(4);
        const N = 8;
        type ArrType = array[1..N] of Integer;
        var A, Sorted: ArrType;
        var rank: array[1..N] of Integer;
        var i, j: Integer;
        begin
          A[1] := 5; A[2] := 2; A[3] := 8; A[4] := 1;
          A[5] := 9; A[6] := 3; A[7] := 7; A[8] := 4;
          forall i := 1 to N do
          begin
            rank[i] := 1;
            for j := 1 to N do
              if (A[j] < A[i]) or ((A[j] = A[i]) and (j < i)) then
                rank[i] := rank[i] + 1;
          end;
          forall i := 1 to N do Sorted[rank[i]] := A[i];
          for i := 1 to N do Write(Sorted[i], ' ');
          WriteLn;
        end.
        """)
        let machine = Machine(program: program)
        machine.start()
        XCTAssertEqual(machine.run(), .completed)
        XCTAssertEqual(machine.output, "1 2 3 4 5 7 8 9 \n")
        XCTAssertGreaterThan(machine.metrics.sequentialTime, machine.metrics.parallelTime)
        XCTAssertGreaterThan(Double(machine.metrics.sequentialTime) / Double(max(1, machine.metrics.parallelTime)), 1.0)
    }


    func testMultidimensionalMatrixMultiplicationInsideForall() throws {
        let machine = try run("""
        program Matrix;
        Architecture Shared(4);
        const N = 4;
        type Matrix = array[1..N,1..N] of Integer;
        var A, B, C: Matrix;
        var i, j, k: Integer;
        begin
          for i := 1 to N do
            for j := 1 to N do
            begin
              A[i,j] := i + j;
              B[i,j] := i - j;
            end;
          forall i := 1 to N do
          begin
            for j := 1 to N do
            begin
              C[i,j] := 0;
              for k := 1 to N do
                C[i,j] := C[i,j] + A[i,k] * B[k,j];
            end;
          end;
          for i := 1 to N do
            for j := 1 to N do
              ;
          writeln(C[1,1], ' ', C[4,4]);
        end.
        """)
        XCTAssertEqual(machine.output, "26 -34\n")
    }

    func testStringLiteralPreservesWholeText() throws {
        let machine = try run("""
        program Strings;
        begin
          writeln('Parent: ', 7, ' child');
        end.
        """)
        XCTAssertEqual(machine.output, "Parent: 7 child\n")
    }

    func testInputRequiredFlag() throws {
        let program = try compile("""
        program NeedsInput;
        var x: Integer;
        begin
          readln(x);
          writeln(x);
        end.
        """)
        XCTAssertTrue(program.requiresInput)
    }

    func testTopologies() throws {
        let cases: [(String, Int)] = [
            ("Shared(4)", 4), ("Line(4)", 4), ("Ring(4)", 4),
            ("Mesh2(2)", 4), ("Torus(2)", 4), ("Mesh3(2)", 8),
            ("Hypercube(3)", 8), ("Bus(4)", 4), ("Star(2)", 4),
            ("Fullconnect(4)", 4)
        ]
        for (architecture, expected) in cases {
            let program = try compile("""
            program Test;
            Architecture \(architecture);
            begin
            end.
            """)
            XCTAssertEqual(program.architecture.topology.processorCount(parameter: program.architecture.parameter), expected)
        }
    }

    func testBreakpointContinue() throws {
        let program = try compile("""
        program Test;
        var x: Integer;
        begin
          x := 1;
          x := 2;
          writeln(x);
        end.
        """)
        let machine = Machine(program: program, options: ProgramOptions(timing: .free))
        machine.breakpoints = [5]
        machine.start()
        XCTAssertEqual(machine.run(), .breakpoint(line: 5))
        XCTAssertEqual(machine.run(), .completed)
        XCTAssertEqual(machine.output, "2\n")
    }

    func testWhileRepeatAndCaseControlFlow() throws {
        let machine = try run("""
        program ControlFlow;
        var x, i, result: Integer;
        begin
          x := 0;
          while x < 3 do x := x + 1;
          i := 0;
          repeat i := i + 1 until i = 2;
          case i of
            1: result := 10;
            2: result := 20;
          else
            result := 30;
          end;
          writeln(x, ' ', i, ' ', result);
        end.
        """)
        XCTAssertEqual(machine.output, "3 2 20\n")
    }

    func testRecordFieldsAndArrayDimensions() throws {
        let machine = try run("""
        program CompositeValues;
        type Pair = record Left: Integer; Right: Integer; end;
        var p: Pair;
        var grid: array[1..2, 1..2] of Integer;
        begin
          p.Left := 4;
          p.Right := 6;
          grid[2,1] := p.Left + p.Right;
          writeln(grid[2,1]);
        end.
        """)
        XCTAssertEqual(machine.output, "10\n")
    }

    func testRecursiveFunctionAndBuiltinMath() throws {
        let machine = try run("""
        program RecursiveFunction;
        function Fact(n: Integer): Integer;
        begin
          if n <= 1 then Fact := 1 else Fact := n * Fact(n - 1);
        end;
        begin
          writeln(Fact(5), ' ', abs(-3), ' ', sqr(4), ' ', odd(7));
        end.
        """)
        XCTAssertEqual(machine.output, "120 3 16 TRUE\n")
    }

    func testWriteFieldWidthAndParameterlessWriteLn() throws {
        let machine = try run("""
        program Formatting;
        begin
          write(12:4);
          writeln;
        end.
        """)
        XCTAssertEqual(machine.output, "  12\n")
    }

    func testForallGroupingExecutesEveryIndex() throws {
        let machine = try run("""
        program GroupDemo;
        Architecture Shared(4);
        var i, total: Integer;
        begin
          total := 0;
          forall i := 1 to 5 grouping 2 do total := total + i;
          writeln(total);
        end.
        """)
        XCTAssertEqual(machine.output, "15\n")
    }

    func testForallNearIntegerLimitDoesNotOverflowGroupedContinuation() throws {
        let machine = try run("""
        program ForallIntLimit;
        var i: Integer;
        begin
          forall i := 9223372036854775806 to 9223372036854775807 grouping 2 do
            writeln(i);
        end.
        """)
        XCTAssertEqual(machine.output, "9223372036854775806\n9223372036854775807\n")
    }

    func testHugeForallRangeIsRejectedBeforeSpawningProcesses() throws {
        let program = try compile("""
        program HugeForall;
        var i: Integer;
        begin
          forall i := 1 to 9223372036854775807 do writeln(i);
        end.
        """)
        let machine = Machine(program: program, options: ProgramOptions(timing: .free))
        machine.start()
        let outcome = machine.run()
        XCTAssertTrue(String(describing: outcome).contains("safety limit of 10000 simulated processes"),
                      "Unexpected outcome: \(outcome)")
        XCTAssertEqual(machine.processes.count, 1, "Reject the workload before allocating child processes")
    }

    func testForallGroupingCannotExceedIterationCount() throws {
        let program = try compile("""
        program BadGrouping;
        var i: Integer;
        begin
          forall i := 1 to 3 grouping 4 do writeln(i);
        end.
        """)
        let machine = Machine(program: program, options: ProgramOptions(timing: .free))
        machine.start()
        let outcome = machine.run()
        XCTAssertTrue(String(describing: outcome).contains("GROUPING cannot exceed"),
                      "Unexpected outcome: \(outcome)")
        XCTAssertEqual(machine.processes.count, 1)
    }

    func testInvalidHugeArchitectureIsDiagnosticNotIntegerOverflow() throws {
        XCTAssertThrowsError(try compile("""
        program BadArchitecture;
        Architecture Mesh3(999999999999);
        begin
        end.
        """)) { error in
            guard let mpError = error as? MPWinError else {
                return XCTFail("Expected a source diagnostic, got \(error)")
            }
            XCTAssertTrue(mpError.description.contains("parameters must be positive integer values"))
        }
    }

    func testOversizedHypercubeIsRejectedWithoutShiftOverflow() throws {
        XCTAssertThrowsError(try compile("""
        program BadHypercube;
        Architecture Hypercube(99999999);
        begin
        end.
        """)) { error in
            XCTAssertTrue(String(describing: error).contains("parameters must be positive integer values"))
        }
    }

    func testOversizedArrayIsRejectedBeforeMemoryAllocation() throws {
        XCTAssertThrowsError(try compile("""
        program HugeArray;
        var data: array[1..32767, 1..32767] of Integer;
        begin
          writeln(1);
        end.
        """)) { error in
            XCTAssertTrue(String(describing: error).contains("Storage overflow"))
        }
    }

    func testPascalOperatorPrecedenceMixedRealsAndBooleanOperators() throws {
        let machine = try run("""
        program Precedence;
        var r: Real;
        begin
          r := 1 + 2.5;
          if 2 + 3 * 4 = 14 and 1 + 2 > 2 then
            writeln(r, ' ', 2 + 3 * 4, ' ', true and false)
          else
            writeln('BAD');
        end.
        """)
        XCTAssertEqual(machine.output, "3.5 14 FALSE\n")
    }

    func testIntegerArithmeticOverflowBecomesRuntimeDiagnostic() throws {
        let program = try compile("""
        program Overflow;
        var x: Integer;
        begin
          x := 9223372036854775807 + 1;
          writeln(x);
        end.
        """)
        let machine = Machine(program: program, options: ProgramOptions(timing: .free))
        machine.start()
        let outcome = machine.run()
        XCTAssertTrue(String(describing: outcome).contains("EXPRESSION EVALUATION OVERFLOW"))
    }

    func testIntegerDivisionOverflowBecomesRuntimeDiagnostic() throws {
        let program = try compile("""
        program DivOverflow;
        var x: Integer;
        begin
          x := ((-9223372036854775807 - 1) div -1);
          writeln(x);
        end.
        """)
        let machine = Machine(program: program, options: ProgramOptions(timing: .free))
        machine.start()
        let outcome = machine.run()
        XCTAssertTrue(String(describing: outcome).contains("EXPRESSION EVALUATION OVERFLOW"))
    }

    func testBooleanValuesComparisonsAndBuiltinTypes() throws {
        let machine = try run("""
        program BooleanTypes;
        var a, b, c: Boolean;
        var integerResult: Integer;
        var realResult: Real;
        begin
          a := true and false;
          b := true xor false;
          c := odd(3);
          integerResult := 6 and 3;
          realResult := abs(-2.5) + sqr(1.5);
          writeln(a, ' ', b, ' ', c, ' ', true <> true, ' ', false <> true, ' ', true <= true, ' ', false < true);
          writeln(integerResult, ' ', realResult);
        end.
        """)
        XCTAssertEqual(machine.output, "FALSE TRUE TRUE FALSE TRUE TRUE TRUE\n2 4.75\n")
    }

    func testLexerRejectsUnterminatedLiteralsCommentsAndNonfiniteReals() throws {
        XCTAssertThrowsError(try Lexer.tokenize("'unterminated"))
        XCTAssertThrowsError(try Lexer.tokenize("{ unterminated comment"))
        XCTAssertThrowsError(try Lexer.tokenize("1e999"))
    }

    func testRealToIntegerOverflowBecomesRuntimeDiagnostic() throws {
        let program = try compile("""
        program RealToIntegerOverflow;
        var x: Integer;
        begin
          x := 1e308;
          writeln(x);
        end.
        """)
        let machine = Machine(program: program, options: ProgramOptions(timing: .free))
        machine.start()
        let outcome = machine.run()
        XCTAssertTrue(String(describing: outcome).contains("EXPRESSION EVALUATION OVERFLOW"))
    }

    func testReadAndReadlnAcrossLines() throws {
        let readln = try run("""
        program Test;
        var x, y: Integer;
        begin
          readln(x);
          readln(y);
          writeln(x, ' ', y);
        end.
        """, input: "5\n7\n")
        XCTAssertEqual(readln.output, "5 7\n")

        let read = try run("""
        program Test;
        var x, y: Integer;
        begin
          read(x);
          read(y);
          writeln(x, ' ', y);
        end.
        """, input: "5\n7\n")
        XCTAssertEqual(read.output, "5 7\n")
    }

    func testEofLoopStopsAfterLastLine() throws {
        let source = """
        program Test;
        var x, total, count: Integer;
        begin
          total := 0;
          count := 0;
          while not eof do
          begin
            readln(x);
            total := total + x;
            count := count + 1;
          end;
          writeln(count, ' ', total);
        end.
        """
        XCTAssertEqual(try run(source, input: "5\n7\n").output, "2 12\n")
        XCTAssertEqual(try run(source, input: "5\r\n7").output, "2 12\n")
    }

    func testReadCharacterAtEndOfLineYieldsBlank() throws {
        let machine = try run("""
        program Test;
        var a, b, c: Char;
        begin
          read(a);
          read(b);
          read(c);
          writeln(a, b, c);
        end.
        """, input: "x\ny\n")
        XCTAssertEqual(machine.output, "x y\n")
    }

    func testProcedureLocalsStartWithDefaults() throws {
        let machine = try run("""
        program Test;
        procedure P(base: Integer);
        var a: array [1..3] of Integer;
            i: Integer;
        begin
          i := i + base;
          a[2] := a[1] + 5;
          writeln(i, ' ', a[2]);
        end;
        begin
          P(4);
        end.
        """)
        XCTAssertEqual(machine.output, "4 5\n")
    }

    func testVarParameterUpdatesCallersLocal() throws {
        // The callee has a local of its own in the slot the caller's variable uses,
        // so resolving the reference in the wrong frame would silently print 10.
        let machine = try run("""
        program Test;
        procedure Bump(var n: Integer);
        var own: Integer;
        begin
          own := 99;
          n := n + 1;
        end;
        procedure Outer;
        var k: Integer;
        begin
          k := 10;
          Bump(k);
          writeln(k);
        end;
        begin
          Outer;
        end.
        """)
        XCTAssertEqual(machine.output, "11\n")
    }

    func testNewAllocatesFreshCell() throws {
        let machine = try run("""
        program Test;
        var p, q: ^Integer;
        begin
          new(p);
          p^ := 1;
          q := p;
          new(p);
          p^ := 2;
          writeln(q^, ' ', p^);
        end.
        """)
        XCTAssertEqual(machine.output, "1 2\n")
    }

    func testCancellationStopsEndlessLoopInsideFunction() throws {
        let program = try compile("""
        program Test;
        function Spin(start: Integer): Integer;
        var i: Integer;
        begin
          i := start;
          while true do i := i + 1;
          Spin := i;
        end;
        var x: Integer;
        begin
          x := Spin(0);
        end.
        """)
        let token = SimulationCancellation()
        let machine = Machine(program: program, options: ProgramOptions(timing: .free),
                              cancellation: token)
        machine.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { token.cancel() }
        XCTAssertEqual(machine.run(), .cancelled)
    }

    func testParameterlessFunctionCallWithoutParentheses() throws {
        let machine = try run("""
        program Test;
        function Answer: Integer;
        begin
          Answer := 42;
        end;
        var x: Integer;
        begin
          x := Answer + 1;
          writeln(x);
        end.
        """)
        XCTAssertEqual(machine.output, "43\n")
    }
}
