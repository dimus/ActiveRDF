# Author:: Eyal Oren
# Copyright:: (c) 2005-2006 Eyal Oren
# License:: LGPL
require 'active_rdf'
require 'federation/connection_pool'
require 'queryengine/query2sparql'
require 'rdf/redland'

# Adapter to Redland database
# uses SPARQL for querying
class RedlandAdapter < ActiveRdfAdapter
	$activerdflog.info "loading Redland adapter"
	ConnectionPool.register_adapter(:redland,self)
	
	# instantiate connection to Redland database
	def initialize(params = {})
    super()

		if params[:location] and params[:location] == :postgresql
			initialize_postgresql(params)
			return
		end

		if params[:location] and params[:location] != :memory
			# setup file defaults for redland database
			type = 'bdb'
                        want_new = false    # create new or use existing store
                        write = true
                        contexts = true

                        if params[:want_new] == true
                           want_new = true
                        end
                        if params[:write] == false
                           write = false
                        end
                        if params[:contexts] == false
                           contexts = false
                        end

      if params[:location].include?('/')
        path, file = File.split(params[:location])
      else
        path = '.'
        file = params[:location]
      end
		else
			# fall back to in-memory redland 	
			type = 'memory'; path = '';	file = '.'; want_new = false; write = true; contexts = true
		end
		
		
		begin
			@store = Redland::HashStore.new(type, file, path, want_new, write, contexts)
			@model = Redland::Model.new @store
			@reads = true
			@writes = true
      $activerdflog.info "initialised Redland adapter to #{@model.inspect}"

		rescue Redland::RedlandError => e
			raise ActiveRdfError, "could not initialise Redland database: #{e.message}"
		end
	end	
	
	# instantiate connection to Redland database in Postgres
	def initialize_postgresql(params = {})
    # author: Richard Dale
		type = 'postgresql'
		name = params[:name]

		options = []
		options << "new='#{params[:new]}'" if params[:new]
    options << "bulk='#{params[:bulk]}'" if params[:bulk]
    options << "merge='#{params[:merge]}'" if params[:merge]
		options << "host='#{params[:host]}'" if params[:host]
		options << "database='#{params[:database]}'" if params[:database]
		options << "user='#{params[:user]}'" if params[:user]
		options << "password='#{params[:password]}'" if params[:password]
		options << "port='#{params[:port]}'" if params[:port]

		
		$activerdflog.info "RedlandAdapter: initializing with type: #{type} name: #{name} options: #{options.join(',')}"
		
		begin
			@store = Redland::TripleStore.new(type, name, options.join(','))
			@model = Redland::Model.new @store
			@reads = true
			@writes = true
		rescue Redland::RedlandError => e
			raise ActiveRdfError, "could not initialise Redland database: #{e.message}"
		end
	end	
	
	# load a file from the given location with the given syntax into the model.
	# use Redland syntax strings, e.g. "ntriples" or "rdfxml", defaults to "ntriples"
	def load(location, syntax="ntriples")
    parser = Redland::Parser.new(syntax, "", nil)
    if location =~ /^http/
      parser.parse_into_model(@model, location)
    else
      parser.parse_into_model(@model, "file:#{location}")
    end
	end

	# yields query results (as many as requested in select clauses) executed on data source
	def query(query)
		qs = Query2SPARQL.translate(query)
    $activerdflog.debug "RedlandAdapter: executing SPARQL query #{qs}"
		
		clauses = query.select_clauses.size
		redland_query = Redland::Query.new(qs, 'sparql')
		query_results = @model.query_execute(redland_query)

		# return Redland's answer without parsing if ASK query
		return [[query_results.get_boolean?]] if query.ask?
		
		$activerdflog.debug "RedlandAdapter: found #{query_results.size} query results"

		# verify if the query has failed
		if query_results.nil?
		  $activerdflog.debug "RedlandAdapter: query has failed with nil result"
		  return false
		end
		if not query_results.is_bindings?
		  $activerdflog.debug "RedlandAdapter: query has failed without bindings"
		  return false
		end


		# convert the result to array
		#TODO: if block is given we should not parse all results into array first
		results = query_result_to_array(query_results) 
		
		if block_given?
			results.each do |clauses|
				yield(*clauses)
			end
		else
			results
		end
	end

	# executes query and returns results as SPARQL JSON or XML results
	# requires svn version of redland-ruby bindings
	# * query: ActiveRDF Query object
	# * result_format: :json or :xml
	def get_query_results(query, result_format=nil)
		get_sparql_query_results(Query2SPARQL.translate(query), result_format)
	end

	# executes sparql query and returns results as SPARQL JSON or XML results
	# * query: sparql query string
	# * result_format: :json or :xml
	def get_sparql_query_results(qs, result_format=nil)
		# author: Eric Hanson

		# set uri for result formatting
		result_uri = 
			case result_format
		 	when :json
        Redland::Uri.new('http://www.w3.org/2001/sw/DataAccess/json-sparql/')
      when :xml
        Redland::Uri.new('http://www.w3.org/TR/2004/WD-rdf-sparql-XMLres-20041221/')
			end

		# query redland
    redland_query = Redland::Query.new(qs, 'sparql')
    query_results = @model.query_execute(redland_query)

		# get string representation in requested result_format (json or xml)
    query_results.to_string()
  end
	
	# add triple to datamodel
	def add(s, p, o)
    $activerdflog.debug "adding triple #{s} #{p} #{o}"

		# verify input
		if s.nil? || p.nil? || o.nil?
      $activerdflog.debug "cannot add triple with empty subject, exiting"
		  return false
		end 
		
		unless s.respond_to?(:uri) && p.respond_to?(:uri)
      $activerdflog.debug "cannot add triple where s/p are not resources, exiting"
		  return false
		end
	
		begin
		  @model.add(wrap(s), wrap(p), wrap(o))		  
			save if ConnectionPool.auto_flush?
		rescue Redland::RedlandError => e
		  $activerdflog.warn "RedlandAdapter: adding triple failed in Redland library: #{e}"
		  return false
		end		
	end

	# deletes triple(s,p,o) from datastore
	# nil parameters match anything: delete(nil,nil,nil) will delete all triples
	def delete(s,p,o)
		s = wrap(s) unless s.nil?
		p = wrap(p) unless p.nil?
		o = wrap(o) unless o.nil?
		@model.delete(s,p,o)
	end

	# saves updates to the model into the redland file location
	def save
		Redland::librdf_model_sync(@model.model).nil?
	end
	alias flush save

	# returns all triples in the datastore
	def dump
		Redland.librdf_model_to_string(@model.model, nil, 'ntriples')
	end
	
	# returns size of datasources as number of triples
	# warning: expensive method as it iterates through all statements
	def size
		# we cannot use @model.size, because redland does not allow counting of 
		# file-based models (@model.size raises an error if used on a file)
		# instead, we just dump all triples, and count them
    @model.triples.size
	end

  # clear all real triples of adapter
  def clear
    @model.find(nil, nil, nil) {|s,p,o| @model.delete(s,p,o)}
  end
	
	# close adapter and remove it from the ConnectionPool
	def close
    ConnectionPool.remove_data_source(self)
  end
	
	private
	################ helper methods ####################
	#TODO: if block is given we should not parse all results into array first
	def query_result_to_array(query_results)
	 	results = []
	 	number_bindings = query_results.binding_names.size
	 	
	 	# walk through query results, and construct results array
	 	# by looking up each result (if it is a resource) and adding it to the result-array
	 	# for literals we only add the values
	 	
	 	# redland results are set that needs to be iterated
	 	while not query_results.finished?
	 		# we collect the bindings in each row and add them to results
	 		results << (0..number_bindings-1).collect do |i|	 		
	 			# node is the query result for one binding
	 			node = query_results.binding_value(i)

				# we determine the node type
 				if node.literal?
 					# for literal nodes we just return the value
 					Redland.librdf_node_get_literal_value(node.node)
 				elsif node.blank?
 				  # blank nodes we ignore
 				  nil
			  else
 				 	# other nodes are rdfs:resources
 					RDFS::Resource.new(node.uri.to_s)
	 			end
	 		end
	 		# iterate through result set
	 		query_results.next
	 	end
	 	results
	end	 	
	
	def wrap node
		case node
		when RDFS::Resource
			Redland::Uri.new(node.uri)
		else
			Redland::Literal.new(node.to_s)
		end
	end
end
