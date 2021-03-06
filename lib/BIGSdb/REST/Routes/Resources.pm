#Written by Keith Jolley
#Copyright (c) 2014-2015, University of Oxford
#E-mail: keith.jolley@zoo.ox.ac.uk
#
#This file is part of Bacterial Isolate Genome Sequence Database (BIGSdb).
#
#BIGSdb is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.
#
#BIGSdb is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.
#
#You should have received a copy of the GNU General Public License
#along with BIGSdb.  If not, see <http://www.gnu.org/licenses/>.
package BIGSdb::REST::Routes::Resources;
use strict;
use warnings;
use 5.010;
use Dancer2 appname => 'BIGSdb::REST::Interface';
get '/robots.txt' => sub { _get_robots() };

#Resource description routes
get '/'           => sub { _get_root() };
get qr{^/db/?+$}x => sub { redirect '/' };
get '/db/:db'     => sub { _get_db() };

sub _get_robots {
	send_file(\"User-agent: *\nDisallow: /\n", content_type => 'text/plain; charset=UTF-8');
	return;
}

sub _get_root {
	my $self            = setting('self');
	my $resource_groups = $self->get_resources;
	my $values          = [];
	foreach my $resource_group (@$resource_groups) {
		if ( $resource_group->{'databases'} ) {
			my $databases = [];
			foreach my $database ( @{ $resource_group->{'databases'} } ) {
				push @$databases,
				  {
					name        => $database->{'dbase_config'},
					description => $database->{'description'},
					href        => request->uri_for("/db/$database->{'dbase_config'}")
				  };
			}
			if ($databases) {
				$resource_group->{'databases'} = $databases;
				push @$values, $resource_group;
			}
		}
	}
	return $values;
}

sub _get_db {
	my $self = setting('self');
	my $db   = params->{'db'};
	if ( !$self->{'system'}->{'db'} ) {
		send_error( "Database '$db' does not exist", 404 );
	}
	my $set_id  = $self->get_set_id;
	my $routes  = {};
	my $schemes = $self->{'datastore'}->get_scheme_list( { set_id => $set_id } );
	$routes->{'schemes'} = request->uri_for("/db/$db/schemes") if @$schemes;
	my $loci = $self->{'datastore'}->get_loci( { set_id => $set_id } );
	$routes->{'loci'} = request->uri_for("/db/$db/loci") if @$loci;
	$routes->{'submissions'} = request->uri_for("/db/$db/submissions")
	  if ( $self->{'system'}->{'submissions'} // '' ) eq 'yes';

	if ( $self->{'system'}->{'dbtype'} eq 'isolates' ) {
		$routes->{'isolates'} = request->uri_for("/db/$db/isolates");
		$routes->{'fields'}   = request->uri_for("/db/$db/fields");
		my $projects = $self->{'datastore'}->run_query('SELECT COUNT(*) FROM projects');
		$routes->{'projects'} = request->uri_for("/db/$db/projects") if $projects;
		return $routes;
	} elsif ( $self->{'system'}->{'dbtype'} eq 'sequences' ) {
		return $routes;
	} else {
		return { title => 'Database configuration is invalid' };
	}
}
1;
