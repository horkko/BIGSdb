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
package BIGSdb::REST::Routes::Schemes;
use strict;
use warnings;
use 5.010;
use JSON;
use Dancer2 appname => 'BIGSdb::REST::Interface';

#Scheme routes
get '/db/:db/schemes'                       => sub { _get_schemes() };
get '/db/:db/schemes/:scheme'               => sub { _get_scheme() };
get '/db/:db/schemes/:scheme/fields/:field' => sub { _get_scheme_field() };

sub _get_schemes {
	my $self        = setting('self');
	my ($db)        = params->{'db'};
	my $set_id      = $self->get_set_id;
	my $schemes     = $self->{'datastore'}->get_scheme_list( { set_id => $set_id } );
	my $values      = { records => int(@$schemes) };
	my $scheme_list = [];
	foreach my $scheme (@$schemes) {
		push @$scheme_list,
		  { scheme => request->uri_for("/db/$db/schemes/$scheme->{'id'}"), description => $scheme->{'name'} };
	}
	$values->{'schemes'} = $scheme_list;
	return $values;
}

sub _get_scheme {
	my $self = setting('self');
	my ( $db, $scheme_id ) = ( params->{'db'}, params->{'scheme'} );
	$self->check_scheme($scheme_id);
	my $values      = {};
	my $set_id      = $self->get_set_id;
	my $scheme_info = $self->{'datastore'}->get_scheme_info( $scheme_id, { set_id => $set_id, get_pk => 1 } );
	$values->{'id'}                    = int($scheme_id);
	$values->{'description'}           = $scheme_info->{'name'};
	$values->{'has_primary_key_field'} = $scheme_info->{'primary_key'} ? JSON::true : JSON::false;
	$values->{'primary_key_field'} = request->uri_for("/db/$db/schemes/$scheme_id/fields/$scheme_info->{'primary_key'}")
	  if $scheme_info->{'primary_key'};
	my $scheme_fields      = $self->{'datastore'}->get_scheme_fields($scheme_id);
	my $scheme_field_links = [];

	foreach my $field (@$scheme_fields) {
		push @$scheme_field_links, request->uri_for("/db/$db/schemes/$scheme_id/fields/$field");
	}
	$values->{'fields'} = $scheme_field_links if @$scheme_field_links;
	my $loci = $self->{'datastore'}->get_scheme_loci($scheme_id);
	$values->{'locus_count'} = scalar @$loci;
	my $locus_links = [];
	foreach my $locus (@$loci) {
		my $cleaned_locus = $self->clean_locus($locus);
		push @$locus_links, request->uri_for("/db/$db/loci/$cleaned_locus");
	}
	$values->{'loci'} = $locus_links if @$locus_links;
	if ( $scheme_info->{'primary_key'} && $self->{'system'}->{'dbtype'} eq 'sequences' ) {
		$values->{'profiles'}     = request->uri_for("/db/$db/schemes/$scheme_id/profiles");
		$values->{'profiles_csv'} = request->uri_for("/db/$db/schemes/$scheme_id/profiles_csv");

		#Curators
		my $curators =
		  $self->{'datastore'}
		  ->run_query( 'SELECT curator_id FROM scheme_curators WHERE scheme_id=? ORDER BY curator_id',
			$scheme_id, { fetch => 'col_arrayref' } );
		my @curator_links;
		foreach my $user_id (@$curators) {
			push @curator_links, request->uri_for("/db/$db/users/$user_id");
		}
		$values->{'curators'} = \@curator_links if @curator_links;
	}
	return $values;
}

sub _get_scheme_field {
	my $self   = setting('self');
	my $params = params;
	my ( $db, $scheme_id, $field ) = @{$params}{qw(db scheme field)};
	$self->check_scheme($scheme_id);
	my $values = {};
	my $field_info = $self->{'datastore'}->get_scheme_field_info( $scheme_id, $field );
	if ( !$field_info ) {
		send_error( "Scheme field $field does not exist in scheme $scheme_id.", 404 );
	}
	foreach my $attribute (qw(field type description)) {
		$values->{$attribute} = $field_info->{$attribute} if defined $field_info->{$attribute};
	}
	$values->{'primary_key'} = $field_info->{'primary_key'} ? JSON::true : JSON::false;
	return $values;
}
1;
