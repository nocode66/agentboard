module Agentboard
  module Workflows
    # Restricted condition grammar (spec §28.2) — never `eval`.
    #
    #   expr    := or
    #   or      := and ("or" and)*
    #   and     := unary ("and" unary)*
    #   unary   := "not" unary | primary
    #   primary := "(" expr ")" | ref op literal | "true" | "false"
    #   ref     := steps.<id>.(status|output.<key>) | ticket.(priority|kind|status)
    #   op      := == | != | < | <= | > | >=
    #   literal := 'string' | "string" | integer | true | false
    class Condition
      class SyntaxError < StandardError; end

      TOKEN = /\s*(?:(\(|\))|(==|!=|<=|>=|<|>)|('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")|(-?\d+)|([A-Za-z_][\w.]*))/
      REF = /\A(?:steps\.[a-z][a-z0-9_]*\.(?:status|output\.[a-z][a-z0-9_]*)|ticket\.(?:priority|kind|status))\z/

      attr_reader :source

      def self.parse(source) = new(source).tap(&:ast)

      def initialize(source)
        @source = source.to_s
        raise SyntaxError, "condition too long" if @source.length > 500
      end

      def ast = (@ast ||= build)

      def step_refs
        refs = []
        walk = ->(node) do
          case node
          in [ :cmp, ref, _, _ ] then refs << ref.split(".")[1] if ref.start_with?("steps.")
          in [ :and | :or, l, r ] then walk.(l); walk.(r)
          in [ :not, x ] then walk.(x)
          else nil
          end
        end
        walk.(ast)
        refs.uniq
      end

      # context: { "steps" => { "test" => { "status" => "succeeded", "output" => {...} } }, "ticket" => {...} }
      def evaluate(context) = eval_node(ast, context)

      private

      def build
        @tokens = tokenize(@source)
        @pos = 0
        node = parse_or
        raise SyntaxError, "unexpected token #{@tokens[@pos].inspect}" if @pos < @tokens.size

        node
      end

      def tokenize(src)
        tokens = []
        rest = src.strip
        until rest.empty?
          m = TOKEN.match(rest)
          raise SyntaxError, "invalid condition near #{rest[0, 20].inspect}" unless m && m.begin(0).zero?

          tokens << if m[1] then [ :paren, m[1] ]
          elsif m[2] then [ :op, m[2] ]
          elsif m[3] then [ :lit, m[3][1..-2].gsub(/\\(.)/, '\1') ]
          elsif m[4] then [ :lit, m[4].to_i ]
          else
            word = m[5]
            case word
            when "and", "or", "not" then [ :kw, word ]
            when "true" then [ :lit, true ]
            when "false" then [ :lit, false ]
            else
              raise SyntaxError, "unknown reference #{word}" unless word.match?(REF)

              [ :ref, word ]
            end
          end
          rest = m.post_match.lstrip
        end
        tokens
      end

      def peek = @tokens[@pos]
      def take = @tokens[@pos].tap { @pos += 1 }

      def parse_or
        left = parse_and
        while peek == [ :kw, "or" ]
          take
          left = [ :or, left, parse_and ]
        end
        left
      end

      def parse_and
        left = parse_unary
        while peek == [ :kw, "and" ]
          take
          left = [ :and, left, parse_unary ]
        end
        left
      end

      def parse_unary
        if peek == [ :kw, "not" ]
          take
          return [ :not, parse_unary ]
        end
        parse_primary
      end

      def parse_primary
        tok = take or raise SyntaxError, "unexpected end of condition"
        case tok
        in [ :paren, "(" ]
          node = parse_or
          raise SyntaxError, "missing )" unless take == [ :paren, ")" ]

          node
        in [ :lit, true | false => v ] then [ :lit, v ]
        in [ :ref, ref ]
          op = take
          raise SyntaxError, "expected comparison operator after #{ref}" unless op&.first == :op

          lit = take
          raise SyntaxError, "expected literal after #{op.last}" unless lit&.first == :lit

          [ :cmp, ref, op.last, lit.last ]
        else
          raise SyntaxError, "unexpected token #{tok.last.inspect}"
        end
      end

      def eval_node(node, ctx)
        case node
        in [ :lit, v ] then v
        in [ :not, x ] then !eval_node(x, ctx)
        in [ :and, l, r ] then eval_node(l, ctx) && eval_node(r, ctx)
        in [ :or, l, r ] then eval_node(l, ctx) || eval_node(r, ctx)
        in [ :cmp, ref, op, lit ]
          value = resolve(ref, ctx)
          compare(value, op, lit)
        end
      end

      def resolve(ref, ctx)
        parts = ref.split(".")
        parts.reduce(ctx) { |acc, key| acc.is_a?(Hash) ? (acc[key] || acc[key.to_sym]) : nil }
      end

      def compare(value, op, lit)
        case op
        when "==" then value == lit || value.to_s == lit.to_s
        when "!=" then !(value == lit || value.to_s == lit.to_s)
        else
          return false unless value.is_a?(Numeric) && lit.is_a?(Numeric)

          value.public_send(op, lit)
        end
      end
    end
  end
end
