module Trailblazer
  module Macro
    def self.Switch(condition:, key: :condition, id: "Switch(#{rand(100)})", &block)
      switch = Switch::Switched.new(key, block)

      condition_task = ->((ctx, flow_options), **circuit_options) {
        Switch::Condition.(ctx, circuit_options, condition: condition)

        return Trailblazer::Activity::Right, [ctx, flow_options]
      }

      switch_block = Class.new(Activity::Railway(name: "Switch")) do
        # pass because we cover the case we want to have a false/nil option
        pass task: condition_task, id: "extract_condition"
        # TODO: the id here it's wrong...I want to get the id from the actual switch option
        step task: switch, id: "switch_step"
      end

      {task: switch_block, id: id, outputs: switch.outputs}
    end

    module Switch
      class OptionNotFound < RuntimeError; end

      class Condition
        def self.call(ctx, circuit_options, condition:)
          Trailblazer::Option(condition).(ctx, ctx.to_hash, circuit_options)
        end
      end

      class Option
        include Trailblazer::Activity::DSL # to use Output, End and Track

        def initialize(condition)
          @condition = condition
          @count = 0
        end

        def option(expression, step, option_signal = {})
          return if @count == 1 # avoid to set @step and @signals twice so the order of the options is important
          # TODO: fix this, this would create issue with false/true and numbers
          return unless expression.match @condition

          @step = step
          @option_signal = option_signal
          @count += 1
        end

        def results
          [@step, @option_signal]
        end
      end

      class Switched
        def initialize(key, block)
          @key = key
          @block = block

          @outputs = Class.new(Activity::FastTrack).to_h[:outputs]
          @outputs = Hash[@outputs.collect { |output| [output.semantic, output] }]

          @signal_to_output = {
            Operation::Railway.pass!      => outputs[:success].signal,
            Operation::Railway.fail!      => outputs[:failure].signal,
            Operation::Railway.pass_fast! => outputs[:pass_fast].signal,
            Operation::Railway.fail_fast! => outputs[:fail_fast].signal,
            true               => outputs[:success].signal,
            false              => outputs[:failure].signal,
            nil                => outputs[:failure].signal
          }
        end

        attr_reader :outputs

        def call((ctx, flow_options), **circuit_options)
          extract_step_and_option_signal(ctx[@key])

          original_signal, (ctx,) = @step[:task].([ctx, flow_options], **circuit_options)

          signal = @signal_to_output.fetch(original_signal, original_signal)

          return signal, [ctx, flow_options]
        end

        def extract_step_and_option_signal(condition)
          options = Option.new(condition)
          options.instance_exec(&@block)
          @step, @option_signal = options.results

          fail Switch::OptionNotFound if @step.nil?

          @step = {task: Trailblazer::Activity::TaskBuilder::Binary(@step)} if @step.is_a?(Symbol)
        end
      end
    end
  end
end
