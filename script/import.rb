#! /usr/bin/env ruby

if RUBY_VERSION.match( /^1\.8/ )
  require 'fastercsv'
  class CSV < FasterCSV
  end
else
  require 'csv'
end

require 'pp'
require 'point'
require 'digest/sha2'

ActiveRecord::Base.logger.level = Logger::Severity::UNKNOWN

def mlog msg
  puts Time.now.to_s(:db) + " " + msg
end
    

legacy = {}

all_stops = {}
cities = {}

mlog "loading stops"
CSV.foreach( File.join( Rails.root, "/tmp/stops.txt" ),
             :headers => true,
             :header_converters => :symbol,
             :encoding => 'UTF-8' ) do |line|
  stop = line.to_hash
  next unless stop[:stop_code].match(/^[0-9]+$/)
  name = stop[:stop_name].downcase.gsub( /[ -_\.]/, '' )
  unless all_stops.has_key? name
    all_stops[name] = []
  end
  all_stops[name] << stop
end

valid_stops = {}
all_stops.each do |shortname,stops|
  checked_stops = { }
  p = Point.new( stops.first[:stop_lat].to_f, stops.first[:stop_lon].to_f )
  checked_stops[p] = [stops.shift]
  stops.each do |stop|
    found = false
    p2 = Point.new( stop[:stop_lat].to_f, stop[:stop_lon].to_f )
    checked_stops.each do |p,cs_stops|
      if p.dist( p2 ) < 200
        found = true
        cs_stops << stop
        break
      end
    end
    if not found
      checked_stops[p2] = [stop]
    end
  end
  if checked_stops.keys.count > 1
    checked_stops.values.each_with_index do|new_stops,idx|
      valid_stops[ shortname + idx.to_s ] = new_stops
    end
  else
    valid_stops[shortname] = checked_stops.values.first
  end
end
all_stops = valid_stops

def line_usage short_name
  if short_name.match(/^\d+$/)
    num_id = short_name.to_i
    if num_id.between?( 40, 49 ) || num_id.between?( 150, 200 ) 
      return :express
    end
    if num_id.between?( 50, 100 )
      return :suburban
    end
    if num_id.between?( 1, 39 )
      return :urban
    end
  end
  if [ "40ex", "KL" ].include? short_name
    return :express
  end
  return :special
end


mlog "loading old routes"
long_names_for_lines = {}
if File.exists? File.join( Rails.root, "/tmp/routes_detailed.txt" )
  CSV.foreach( File.join( Rails.root, "/tmp/routes_detailed.txt" ),
               :headers => true,
               :header_converters => :symbol,
               :encoding => 'UTF-8' ) do |rawline|
    line = rawline.to_hash
    long_names_for_lines[ line[:route_short_name] ] = line[:route_long_name]
  end
end

legacy[:line] = {}
lines_stops = {}
all_headsigns = {}
mlog "loading routes"
ActiveRecord::Base.transaction do
  CSV.foreach( File.join( Rails.root, "/tmp/routes.txt" ),
               :headers => true,
               :header_converters => :symbol,
               :encoding => 'UTF-8' ) do |rawline|
    line = rawline.to_hash
    new_line = Line.create({ :src_id => line[:route_id],
                             :short_name => line[:route_short_name],
                             :long_name => long_names_for_lines.has_key?( line[:route_short_name] ) ? long_names_for_lines[line[:route_short_name]] :  line[:route_long_name],
                             :bgcolor => line[:route_color],
                             :fgcolor => line[:route_text_color],
                             :usage => line_usage( line[:route_short_name] ) })
    legacy[:line][line[:route_id]] = new_line
    lines_stops[new_line.id] = {}
    all_headsigns[new_line.id] = {}
  end
end
calendar = {}
mlog "loading calendar"
CSV.foreach( File.join( Rails.root, "/tmp/calendar.txt" ),
             :headers => true,
             :header_converters => :symbol,
             :encoding => 'UTF-8' ) do |line|
  cal = line.to_hash
  id = cal[:service_id]
  calendar[id] = 0
  cal.keys.grep(/day$/) do|k|
    if cal[k] == "1"
      calendar[id] |= Calendar.const_get( k.upcase )
    end
  end
end

legacy[:trip] = {}

mlog "loading trips"
ActiveRecord::Base.transaction do
  CSV.foreach( File.join( Rails.root, "/tmp/trips.txt" ),
               :headers => true,
               :header_converters => :symbol,
               :encoding => 'UTF-8' ) do |rawline|
    line = rawline.to_hash
    unless all_headsigns[legacy[:line][line[:route_id]].id].has_key? line[:trip_headsign]
      headsign = Headsign.create({ :name => line[:trip_headsign].gsub( /.*\| /, '' ),
                                   :line_id => legacy[:line][line[:route_id]].id })
      all_headsigns[legacy[:line][line[:route_id]].id][line[:trip_headsign]] = headsign
    end
    trip = Trip.create({ :src_id => line[:trip_id],
                         :line_id => legacy[:line][line[:route_id]].id,
                         :calendar => calendar[line[:service_id]],
                         :src_route_id => line[:route_id],
                         :headsign_id => all_headsigns[legacy[:line][line[:route_id]].id][line[:trip_headsign]].id,
                         :block_id => line[:block_id] })
    legacy[:trip][line[:trip_id]] = {  :line => legacy[:line][line[:route_id]], :calendar => calendar[line[:service_id]], :headsign_id => trip.headsign_id, :id => trip.id }
    
  end
end  
def average array
  array.inject{ |sum, el| sum + el }.to_f / array.size
end
    

legacy[:stops] = {}
mlog "storing stops"
all_new_stops = {}
ActiveRecord::Base.transaction do
  all_stops.each do |short_name,stops|
    real_name = ''
    names = stops.collect {|s| s[:stop_name] }
    if names.uniq.length == 1
      real_name = names.first
    else
      counts = names.inject(Hash.new(0)) {|h,i| h[i] += 1; h }
      real_name = counts.keys.sort { |a,b| counts[a] <=> counts[b] }.last
    end
    city_name = stops.first[:stop_desc]
    unless cities.has_key? city_name
      cities[city_name] = City.create({ :name => city_name })
    end
    new_stop = Stop.create({ :name => real_name, 
                             :lat => average( stops.collect{|s| s[:stop_lat].to_f } ),
                             :lon => average( stops.collect{|s| s[:stop_lon].to_f } ),
                             :city_id => cities[city_name].id })
    stops.each do |stop|
      new_stop.stop_aliases.create({ :src_id => stop[:stop_id],
                                     :src_code => stop[:stop_code],
                                     :src_name => stop[:stop_name],
                                     :src_lat => stop[:stop_lat],
                                     :src_lon => stop[:stop_lon] })
      legacy[:stops][stop[:stop_id]] = new_stop.id
    end
    all_new_stops[new_stop.id] = new_stop
  end
end
mlog "loading stop_times"


def flush stop_times
  return if stop_times.empty?
  sql = <<SQL
  INSERT INTO stop_times 
    ( stop_id, line_id, trip_id, headsign_id, calendar, arrival, departure )
  VALUES
SQL
  sql += stop_times.collect do |stoptime|
    "(" + [ stoptime.stop_id, stoptime.line_id, stoptime.trip_id, stoptime.headsign_id, stoptime.calendar, stoptime.arrival, stoptime.departure ].join(",") + ")"
  end.join(",")
  ActiveRecord::Base.connection.execute( sql )
  stop_times.clear
end
    

ActiveRecord::Base.transaction do
  all_stop_times = []
  CSV.foreach( File.join( Rails.root, "/tmp/stop_times.txt" ),
               :headers => true,
               :header_converters => :symbol,
               :encoding => 'UTF-8' ) do |rawline|
    line = rawline.to_hash
    if ! legacy[:trip].has_key?(line[:trip_id])
      #    puts "Missing trip #{line[:trip_id]}"
      next
    end
    # candidate for inlining
    st = StopTime.new({ :stop_id => legacy[:stops][line[:stop_id]],
                           :line_id => legacy[:trip][line[:trip_id]][:line].id,
                           :trip_id => legacy[:trip][line[:trip_id]][:id],
                           :headsign_id => legacy[:trip][line[:trip_id]][:headsign_id],
                           :calendar => legacy[:trip][line[:trip_id]][:calendar],
                           :arrival => line[:arrival_time].split(':').inject(0) { |m,v| m = m * 60 + v.to_i },
                           :departure => line[:departure_time].split(':').inject(0) { |m,v| m = m * 60 + v.to_i }
                         })
    all_stop_times.push( st )
    lines_stops[st.line_id][st.stop_id] = 1
    if all_stop_times.length > 1000
      flush all_stop_times
    end
  end
  flush all_stop_times
  ActiveRecord::Base.connection.execute( "UPDATE stop_times SET created_at = now(), updated_at = now()" )
end

mlog "Linking lines and stops"
ActiveRecord::Base.transaction do
  Line.all.each do |line|
    line.stops = lines_stops[line.id].keys.collect {|stop_id| all_new_stops[stop_id] }.reject{|x| x.nil? }
    line.save
  end
end
mlog "Generating stop line cache"
ActiveRecord::Base.transaction do
  Stop.all.each do |stop|
    stop.line_ids_cache = stop.lines.collect(&:id).join(",")
    stop.save
  end
end

mlog "Adding index for stop_times/trips"
ActiveRecord::Migration.add_index( :stop_times, [ :trip_id ] )

mlog "This is gonna' be ugly"
Line.all.each do |line|
  keytrips = {}
 
  line.trips.of_week_day(Calendar::WEEKDAY).each do |trip|
    signer = Digest::SHA2.new
    trip.stop_times.order('arrival ASC').each do |st|
      signer << st.arrival.to_s << st.stop_id.to_s
    end
    unless keytrips.has_key? signer.digest
      keytrips[signer.digest] = []
    end
    keytrips[signer.digest] << trip.id
  end
  mlog "Line #{line.long_name} has #{line.trips.count} trips for #{keytrips.keys.count} digests"
  keytrips.each do |k,ts|
    next if ts.count == 1
    trips = Trip.find( ts )
    final_trip = trips.shift
    final_trip.calendar = trips.inject(final_trip.calendar) { |acc,t| acc |= t.calendar }
    ActiveRecord::Base.transaction do
      final_trip.stop_times.update_all( { :calendar => final_trip.calendar } )
      trips.each do |t| 
        t.stop_times.delete_all
        t.delete
      end
      final_trip.save
    end
  end
  mlog "End of purge for #{line.long_name}"
end

ActiveRecord::Base.transaction do
  Trip.all.each do |trip|
    start = trip.stop_times.order(:arrival).first.stop
    stop = trip.stop_times.order(:arrival).last.stop
    bearing = start.to_point.bearing( stop.to_point )
    next if bearing.nil?
    base_dir = bearing > 0 ? 'E' : 'W'
    dirs = [ 'N', 'N' + base_dir, 'N' + base_dir, base_dir, base_dir, 'S' + base_dir, 'S' + base_dir, 'S' ] 
    trip.bearing = dirs[ (bearing.abs * 8 / 180).floor ]
    trip.save
  end
end

if in_memory_database?
  mlog "Dumping memory to file"
  import_db = ActiveRecord::Base.connection.raw_connection
  output_db = SQLite3::Database.new( File.join( Rails.root, "/db/import.db" ) )
  backup = SQLite3::Backup.new( output_db, 'main', import_db, 'main')
  backup.step(-1) 
  backup.finish
end
mlog "The end"
