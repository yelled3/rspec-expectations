module RSpec
  module Matchers
    # Defines the custom matcher DSL.
    module DSL
      # Defines a custom matcher.
      # @see RSpec::Matchers
      def define(name, &declarations)
        define_method name do |*expected|
          RSpec::Matchers::DSL::Matcher.new(name, declarations, self, *expected)
        end
      end
      alias_method :matcher, :define

      # Defines a custom negated matcher.
      # @see RSpec::Matchers
      def define_negated_matcher(name, base_matcher, &declarations)
        define_method name do |*expected|
          RSpec::Matchers::DSL::Matcher.new(name, declarations, self, *expected)
        end
      end
      alias_method :negated_matcher, :define_negated_matcher

      if RSpec.respond_to?(:configure)
        RSpec.configure {|c| c.extend self}
      end

      # Contains the methods that are available from within the
      # `RSpec::Matchers.define` DSL for creating custom matchers.
      module Macros
        # Stores the block that is used to determine whether this matcher passes
        # or fails. The block should return a boolean value. When the matcher is
        # passed to `expect(...).to` and the block returns `true`, then the expectation
        # passes. Similarly, when the matcher is passed to `expect(...).not_to` and the
        # block returns `false`, then the expectation passes.
        #
        # @example
        #
        #     RSpec::Matchers.define :be_even do
        #       match do |actual|
        #         actual.even?
        #       end
        #     end
        #
        #     expect(4).to be_even     # passes
        #     expect(3).not_to be_even # passes
        #     expect(3).to be_even     # fails
        #     expect(4).not_to be_even # fails
        #
        # @yield [Object] actual the actual value (i.e. the value wrapped by `expect`)
        def match(&match_block)
          define_user_override(:matches?, match_block) do |actual|
            begin
              @actual = actual
              super(*actual_arg_for(match_block))
            rescue RSpec::Expectations::ExpectationNotMetError
              false
            end
          end
        end

        # Use this to define the block for a negative expectation (`expect(...).not_to`)
        # when the positive and negative forms require different handling. This
        # is rarely necessary, but can be helpful, for example, when specifying
        # asynchronous processes that require different timeouts.
        #
        # @yield [Object] actual the actual value (i.e. the value wrapped by `expect`)
        def match_when_negated(&match_block)
          define_user_override(:does_not_match?, match_block) do |actual|
            @actual = actual
            super(*actual_arg_for(match_block))
          end
        end

        # Use this instead of `match` when the block will raise an exception
        # rather than returning false to indicate a failure.
        #
        # @example
        #
        #     RSpec::Matchers.define :accept_as_valid do |candidate_address|
        #       match_unless_raises ValidationException do |validator|
        #         validator.validate(candidate_address)
        #       end
        #     end
        #
        #     expect(email_validator).to accept_as_valid("person@company.com")
        #
        # @yield [Object] actual the actual object (i.e. the value wrapped by `expect`)
        def match_unless_raises(expected_exception=Exception, &match_block)
          define_user_override(:matches?, match_block) do |actual|
            @actual = actual
            begin
              super(*actual_arg_for(match_block))
            rescue expected_exception => @rescued_exception
              false
            else
              true
            end
          end
        end

        # Customizes the failure messsage to use when this matcher is
        # asked to positively match. Only use this when the message
        # generated by default doesn't suit your needs.
        #
        # @example
        #
        #     RSpec::Matchers.define :have_strength do |expected|
        #       match { your_match_logic }
        #
        #       failure_message do |actual|
        #         "Expected strength of #{expected}, but had #{actual.strength}"
        #       end
        #     end
        #
        # @yield [Object] actual the actual object (i.e. the value wrapped by `expect`)
        def failure_message(&definition)
          define_user_override(__method__, definition)
        end

        # Customize the failure messsage to use when this matcher is asked
        # to negatively match. Only use this when the message generated by
        # default doesn't suit your needs.
        #
        # @example
        #
        #     RSpec::Matchers.define :have_strength do |expected|
        #       match { your_match_logic }
        #
        #       failure_message_when_negated do |actual|
        #         "Expected not to have strength of #{expected}, but did"
        #       end
        #     end
        #
        # @yield [Object] actual the actual object (i.e. the value wrapped by `expect`)
        def failure_message_when_negated(&definition)
          define_user_override(__method__, definition)
        end

        # Customize the description to use for one-liners.  Only use this when
        # the description generated by default doesn't suit your needs.
        #
        # @example
        #
        #     RSpec::Matchers.define :qualify_for do |expected|
        #       match { your_match_logic }
        #
        #       description do
        #         "qualify for #{expected}"
        #       end
        #     end
        #
        # @yield [Object] actual the actual object (i.e. the value wrapped by `expect`)
        def description(&definition)
          define_user_override(__method__, definition)
        end

        # Tells the matcher to diff the actual and expected values in the failure
        # message.
        def diffable
          define_method(:diffable?) { true }
        end

        # Convenience for defining methods on this matcher to create a fluent
        # interface. The trick about fluent interfaces is that each method must
        # return self in order to chain methods together. `chain` handles that
        # for you.
        #
        # @example
        #
        #     RSpec::Matchers.define :have_errors_on do |key|
        #       chain :with do |message|
        #         @message = message
        #       end
        #
        #       match do |actual|
        #         actual.errors[key] == @message
        #       end
        #     end
        #
        #     expect(minor).to have_errors_on(:age).with("Not old enough to participate")
        def chain(name, &definition)
          define_user_override(name, definition) do |*args, &block|
            super(*args, &block)
            self
          end
        end

      private

        # Does the following:
        #
        # - Defines the named method usign a user-provided block
        #   in @user_method_defs, which is included as an ancestor
        #   in the singleton class in which we eval the `define` block.
        # - Defines an overriden definition for the same method
        #   usign the provided `our_def` block.
        # - Provides a default `our_def` block for the common case
        #   of needing to call the user's definition with `@actual`
        #   as an arg, but only if their block's arity can handle it.
        #
        # This compiles the user block into an actual method, allowing
        # them to use normal method constructs like `return`
        # (e.g. for a early guard statement), while allowing us to define
        # an override that can provide the wrapped handling
        # (e.g. assigning `@actual`, rescueing errors, etc) and
        # can `super` to the user's definition.
        def define_user_override(method_name, user_def, &our_def)
          @user_method_defs.__send__(:define_method, method_name, &user_def)
          our_def ||= lambda { super(*actual_arg_for(user_def)) }
          define_method(method_name, &our_def)
        end

        # Defines deprecated macro methods from RSpec 2 for backwards compatibility.
        # @deprecated Use the methods from {Macros} instead.
        module Deprecated
          # @deprecated Use {Macros#match} instead.
          def match_for_should(&definition)
            RSpec.deprecate("`match_for_should`", :replacement => "`match`")
            match(&definition)
          end

          # @deprecated Use {Macros#match_when_negated} instead.
          def match_for_should_not(&definition)
            RSpec.deprecate("`match_for_should_not`", :replacement => "`match_when_negated`")
            match_when_negated(&definition)
          end

          # @deprecated Use {Macros#failure_message} instead.
          def failure_message_for_should(&definition)
            RSpec.deprecate("`failure_message_for_should`", :replacement => "`failure_message`")
            failure_message(&definition)
          end

          # @deprecated Use {Macros#failure_message_when_negated} instead.
          def failure_message_for_should_not(&definition)
            RSpec.deprecate("`failure_message_for_should_not`", :replacement => "`failure_message_when_negated`")
            failure_message_when_negated(&definition)
          end
        end
      end

      # Defines default implementations of the matcher
      # protocol methods for custom matchers. You can
      # override any of these using the {RSpec::Matchers::DSL::Macros Macros} methods
      # from within an `RSpec::Matchers.define` block.
      module DefaultImplementations
        # @api private
        # Used internally by objects returns by `should` and `should_not`.
        def diffable?
          false
        end

        # The default description.
        def description
          "#{name_to_sentence}#{to_sentence expected}"
        end

        # The default failure message for positive expectations.
        def failure_message
          "expected #{actual.inspect} to #{name_to_sentence}#{to_sentence expected}"
        end

        # The default failure message for negative expectations.
        def failure_message_when_negated
          "expected #{actual.inspect} not to #{name_to_sentence}#{to_sentence expected}"
        end
      end

      # The class used for custom matchers. The block passed to
      # `RSpec::Matchers.define` will be evaluated in the context
      # of the singleton class of an instance, and will have the
      # {RSpec::Matchers::DSL::Macros Macros} methods available.
      class Matcher
        # Provides default implementations for the matcher protocol methods.
        include DefaultImplementations

        # Allows expectation expressions to be used in the match block.
        include RSpec::Matchers

        # Converts matcher name and expected args to an English expresion.
        include RSpec::Matchers::Pretty

        # Supports the matcher composability features of RSpec 3+.
        include Composable

        # Makes the macro methods available to an `RSpec::Matchers.define` block.
        extend Macros
        extend Macros::Deprecated

        # Exposes the value being matched against -- generally the object
        # object wrapped by `expect`.
        attr_reader :actual

        # Exposes the exception raised during the matching by `match_unless_raises`.
        # Could be useful to extract details for a failure message.
        attr_reader :rescued_exception

        # @api private
        def initialize(name, declarations, matcher_execution_context, *expected)
          @name     = name
          @actual   = nil
          @expected_as_array = expected
          @matcher_execution_context = matcher_execution_context

          class << self
            # See `Macros#define_user_override` above, for an explanation.
            include(@user_method_defs = Module.new)
            self
          end.class_exec(*expected, &declarations)
        end

        # Provides the expected value. This will return an array if
        # multiple arguments were passed to the matcher; otherwise it
        # will return a single value.
        # @see #expected_as_array
        def expected
          if expected_as_array.size == 1
            expected_as_array[0]
          else
            expected_as_array
          end
        end

        # Returns the expected value as an an array. This exists primarily
        # to aid in upgrading from RSpec 2.x, since in RSpec 2, `expected`
        # always returned an array.
        # @see #expected
        attr_reader :expected_as_array

        # Adds the name (rather than a cryptic hex number)
        # so we can identify an instance of
        # the matcher in error messages (e.g. for `NoMethodError`)
        def inspect
          "#<#{self.class.name} #{name}>"
        end

        if RUBY_VERSION.to_f >= 1.9
          # Indicates that this matcher responds to messages
          # from the `@matcher_execution_context` as well.
          # Also, supports getting a method object for such methods.
          def respond_to_missing?(method, include_private=false)
            super || @matcher_execution_context.respond_to?(method, include_private)
          end
        else # for 1.8.7
          # Indicates that this matcher responds to messages
          # from the `@matcher_execution_context` as well.
          def respond_to?(method, include_private=false)
            super || @matcher_execution_context.respond_to?(method, include_private)
          end
        end

      private

        def actual_arg_for(block)
          block.arity.zero? ? [] : [@actual]
        end

        # Takes care of forwarding unhandled messages to the
        # `@matcher_execution_context` (typically the current
        # running `RSpec::Core::Example`). This is needed by
        # rspec-rails so that it can define matchers that wrap
        # Rails' test helper methods, but it's also a useful
        # feature in its own right.
        def method_missing(method, *args, &block)
          if @matcher_execution_context.respond_to?(method)
            @matcher_execution_context.__send__ method, *args, &block
          else
            super(method, *args, &block)
          end
        end
      end
    end
  end
end

RSpec::Matchers.extend RSpec::Matchers::DSL
