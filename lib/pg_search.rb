require "active_record"

module PgSearch
  def self.included(base)
    base.send(:extend, ClassMethods)
  end

  module ClassMethods
    def pg_search_scope(name, scope_options_or_proc)
      options_proc = case scope_options_or_proc
        when Proc
          scope_options_or_proc
        when Hash
          lambda do |query|
            scope_options_or_proc.reverse_merge(
              :query => query
            )
          end
        else
          raise ArgumentError, "#{__method__} expects a Proc or Hash for its options"
      end

      scope_method = if self.respond_to?(:scope) && !protected_methods.include?('scope')
                       :scope
                     else
                       :named_scope
                     end

      send(scope_method, name, lambda { |*args|
        options = options_proc.call(*args).reverse_merge(:using => :tsearch)

        options.assert_valid_keys(:against, :ranked_by, :normalizing, :with_dictionary, :using, :query)
        Array.wrap(options[:using]).each do |using_value|
          unless [:trigram, :tsearch].include?(using_value)
            raise ArgumentError, ":using cannot accept foo"
          end
        end
        Array.wrap(options[:normalizing]).each do |using_value|
          unless [:prefixes, :diacritics].include?(using_value)
            raise ArgumentError, ":normalizing cannot accept foo"
          end
        end

        query = options[:query].to_s
        normalizing = Array.wrap(options[:normalizing])
        dictionary = options[:with_dictionary]

        raise ArgumentError, "the search scope #{name} must have :against in its options" unless options[:against]

        against = options[:against]
        against = Array.wrap(against) unless against.is_a?(Hash)

        columns_with_weights = against.map do |column_name, weight|
          ["coalesce(#{quoted_table_name}.#{connection.quote_column_name(column_name)}, '')",
           weight]
        end

        document = columns_with_weights.map { |column, *| column }.join(" || ' ' || ")

        normalized = lambda do |string|
          string = "unaccent(#{string})" if normalizing.include?(:diacritics)
          string
        end

        tsquery = query.split(" ").compact.map do |term|
          term = term.gsub("'", " ")
          term = "'#{term}'"
          term = "#{term}:*" if normalizing.include?(:prefixes)
          "to_tsquery(#{":dictionary," if dictionary} #{normalized[connection.quote(term)]})"
        end.join(" && ")

        tsdocument = columns_with_weights.map do |column, weight|
          tsvector = "to_tsvector(#{":dictionary," if dictionary} #{normalized[column]})"
          weight.nil? ? tsvector : "setweight(#{tsvector}, #{connection.quote(weight)})"
        end.join(" || ")

        conditions_hash = {
          :tsearch => "(#{tsdocument}) @@ (#{tsquery})",
          :trigram => "(#{normalized[document]}) % #{normalized[":query"]}"
        }

        conditions = Array.wrap(options[:using]).map do |feature|
          "(#{conditions_hash[feature]})"
        end.join(" OR ")

        interpolations = {
          :query => query,
          :dictionary => dictionary.to_s
        }

        tsearch_rank = sanitize_sql_array(["ts_rank((#{tsdocument}), (#{tsquery}))", interpolations])

        rank = options[:ranked_by] || ":tsearch_rank"
        rank = rank.gsub(':tsearch_rank', tsearch_rank)

        {
          :select => "#{quoted_table_name}.*, (#{rank}) AS rank",
          :conditions => [conditions, interpolations],
          :order => "rank DESC, #{quoted_table_name}.#{connection.quote_column_name(primary_key)} ASC"
        }
      })
    end
  end

  def rank
    attributes['rank'].to_f
  end
end
