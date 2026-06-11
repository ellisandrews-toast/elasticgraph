# Copyright 2024 - 2026 Block, Inc.
#
# Use of this source code is governed by an MIT-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/MIT.
#
# frozen_string_literal: true

require "elastic_graph/schema_artifacts/runtime_metadata/params"
require "elastic_graph/schema_artifacts/runtime_metadata/sourced_from_nested_params"
require "elastic_graph/schema_definition/indexing/update_target_factory"
require "elastic_graph/schema_definition/indexing/update_target_resolver_support"

module ElasticGraph
  module SchemaDefinition
    module Indexing
      # Resolves a relationship and a set of `sourced_from` fields into an `UpdateTarget` that instructs the
      # indexer how to update a type from the related type's source events. This handles the *nested* case,
      # where the `sourced_from` fields live on a type embedded within an indexed type (reached via a
      # `parent_relationship` chain) and the target updates the root indexed type the embedded type nests
      # within. (The *top-level* case—`sourced_from` fields directly on an indexed type—is handled by
      # `TopLevelUpdateTargetResolver`.)
      #
      # @private
      class NestedUpdateTargetResolver
        def initialize(
          object_type:,
          sourced_fields:,
          resolved_chain:,
          field_path_resolver:,
          schema_def_state:
        )
          @object_type = object_type
          @sourced_fields = sourced_fields
          @resolved_chain = resolved_chain
          @field_path_resolver = field_path_resolver
          @schema_def_state = schema_def_state
        end

        # Resolves the chain and `sourced_fields` into an `UpdateTarget` on the root indexed type,
        # validating everything along the way.
        #
        # Returns a tuple of the `update_target` (if valid) and a list of errors.
        def resolve
          relationship_errors = validate_relationship
          field_params, field_params_errors = UpdateTargetResolverSupport.resolve_sourced_field_params(
            object_type: object_type,
            related_type: related_type,
            sourced_fields: sourced_fields,
            field_path_resolver: field_path_resolver
          )
          routing_value_source, routing_error = resolve_field_source(UpdateTargetResolverSupport::RoutingSourceAdapter)
          rollover_timestamp_value_source, rollover_timestamp_error = resolve_field_source(UpdateTargetResolverSupport::RolloverTimestampSourceAdapter)
          has_had_multiple_sources_errors = validate_has_had_multiple_sources

          all_errors = relationship_errors + field_params_errors + has_had_multiple_sources_errors +
            [routing_error, rollover_timestamp_error].compact

          if all_errors.empty?
            update_target = UpdateTargetFactory.new_normal_indexing_update_target(
              type: root_type.name,
              relationship: resolved_chain.qualified_relationship,
              id_source: root_relationship.foreign_key,
              sourced_from_nested_params: SchemaArtifacts::RuntimeMetadata::SourcedFromNestedParams.new(
                field_params: field_params,
                path_identifier_params: build_path_identifier_params
              ),
              routing_value_source: routing_value_source,
              rollover_timestamp_value_source: rollover_timestamp_value_source
            )
          end

          [update_target, all_errors]
        end

        private

        # @dynamic object_type, sourced_fields, resolved_chain, field_path_resolver, schema_def_state
        attr_reader :object_type, :sourced_fields, :resolved_chain, :field_path_resolver, :schema_def_state

        # The leaf relationship the chain was resolved from — the one backing this type's `sourced_from` fields.
        def relationship
          resolved_chain.leaf_relationship
        end

        def root_relationship
          resolved_chain.root_relationship
        end

        def root_type
          root_relationship.parent_type
        end

        def root_index
          resolved_chain.root_index
        end

        def related_type
          @related_type ||= schema_def_state.object_types_by_name.fetch(relationship.related_type.unwrap_non_null.name)
        end

        # Applies validations specific to relationships backing nested `sourced_from` fields.
        def validate_relationship
          errors = [] # : ::Array[::String]

          if relationship.many?
            errors << "`#{object_type.name}.#{relationship.name}` is a `relates_to_many` relationship, but nested " \
              "`sourced_from` is only supported on a `relates_to_one` relationship."
          end

          errors
        end

        # Builds the params identifying which nested element to update: one entry per list segment in the
        # chain, pulling the matching value from the segment's foreign key on the source event. Object
        # segments have no ambiguity, so they contribute no identifier.
        def build_path_identifier_params
          resolved_chain.path_segments.filter_map do |segment|
            source_field = segment.source_field_name
            next unless source_field

            param = SchemaArtifacts::RuntimeMetadata::DynamicParam.new(
              source_path: source_field,
              cardinality: :one
            )

            [source_field, param]
          end.to_h
        end

        # Resolves a routing/rollover field source via the shared helper, supplying the root type, index, and
        # relationship — the update target updates the root indexed type via the root relationship, so routing
        # and rollover (and the `equivalent_field` config) are resolved there.
        def resolve_field_source(adapter)
          UpdateTargetResolverSupport.resolve_field_source(
            adapter,
            relationship: root_relationship,
            index_def: root_index,
            related_type: related_type,
            field_path_resolver: field_path_resolver,
            updated_type: root_type
          )
        end

        # Validates that `has_had_multiple_sources!` has been configured on the root index, since nested
        # `sourced_from` makes the root index multi-sourced.
        def validate_has_had_multiple_sources
          return [] if root_index.has_had_multiple_sources_flag

          ["Type `#{root_type.name}` has nested `sourced_from` fields (via `#{object_type.name}.#{relationship.name}`) but " \
            "its index `#{root_index.name}` has not been configured with `has_had_multiple_sources!`. To resolve this, add " \
            "`i.has_had_multiple_sources!` within the `t.index \"#{root_index.name}\"` block. This flag is required because " \
            "indices with multiple sources can contain incomplete documents, and ElasticGraph needs to know this to apply " \
            "proper filtering. Once set, this flag should remain even if you later remove all `sourced_from` fields, as the " \
            "index may still contain historical incomplete documents."]
        end
      end
    end
  end
end
