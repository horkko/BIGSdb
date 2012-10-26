#Written by Keith Jolley
#Copyright (c) 2010-2012, University of Oxford
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
package BIGSdb::AlleleQueryPage;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::QueryPage);
use List::MoreUtils qw(any none);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Page');
use constant MAX_ROWS => 10;
use BIGSdb::Page qw(ALLELE_FLAGS);
use BIGSdb::QueryPage qw(OPERATORS);

sub initiate {
	my ($self) = @_;
	if ( $self->{'cgi'}->param('no_header') ) {
		$self->{'type'} = 'no_header';
		return;
	}
	$self->{$_} = 1 foreach qw(jQuery tooltips);
	$self->{'noCache'} = 1 if ( $self->{'system'}->{'sets'} // '' ) eq 'yes';
	return;
}

sub get_javascript {
	my ($self)   = @_;
	my $q        = $self->{'cgi'};
	my $max_rows = MAX_ROWS;
	my $buffer   = << "END";
\$(function () {
 \$("#locus").change(function(){
 	var locus_name = \$("#locus").val();
 	locus_name = locus_name.replace("cn_","");
  	var url = '$self->{'system'}->{'script_name'}?db=$self->{'instance'}&page=alleleQuery&locus=' + locus_name;
 	location.href=url;
  });
  \$('a[rel=ajax]').click(function(){
  	\$(this).attr('href', function(){
  		if (this.href.match(/javascript.loadContent/)){
  			return;
  		};
   		return(this.href.replace(/(.*)/, "javascript:loadContent\('\$1\'\)"));
   	});
  });
});

function loadContent(url) {
	var row = parseInt(url.match(/row=(\\d+)/)[1]);
	var new_row = row+1;
	\$("ul#table_fields").append('<li id="fields' + row + '" />');
	\$("li#fields"+row).html('<img src=\"/javascript/themes/default/throbber.gif\" /> Loading ...').load(url);
	url = url.replace(/row=\\d+/,'row='+new_row);
	\$("#add_table_fields").attr('href',url);
	\$("span#table_field_heading").show();
	if (new_row > $max_rows){
		\$("#add_table_fields").hide();
	}
}
END
	return $buffer;
}

sub _ajax_content {
	my ( $self, $locus ) = @_;
	my $row = $self->{'cgi'}->param('row');
	return if !BIGSdb::Utils::is_int($row) || $row > MAX_ROWS || $row < 2;
	my ( $select_items, $labels ) = $self->_get_select_items($locus);
	$self->_print_table_fields( $locus, $row, 0, $select_items, $labels );
	return;
}

sub print_content {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	my $locus = $q->param('locus') || '';
	$locus =~ s/^cn_//;
	if ( $q->param('no_header') ) {
		$self->_ajax_content($locus);
		return;
	}
	my $cleaned_locus = $self->clean_locus($locus);
	my $desc          = $self->get_db_description;
	print "<h1>Query $cleaned_locus sequences - $desc database</h1>\n";
	my $qry;
	if (   !defined $q->param('currentpage')
		|| ( defined $q->param('pagejump') && $q->param('pagejump') eq '1' )
		|| $q->param('First') )
	{
		if ( !$q->param('no_js') ) {
			my $locus_clause = $locus ? "&amp;locus=$locus" : '';
			print
"<noscript><div class=\"box statusbad\"><p>The dynamic customisation of this interface requires that you enable Javascript in your "
			  . "browser. Alternatively, you can use a <a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=alleleQuery"
			  . "$locus_clause&amp;no_js=1\">non-Javascript version</a> that has 4 combinations of fields.</p></div></noscript>\n";
		}
		$self->_print_query_interface();
	}
	if (   defined $q->param('query')
		|| defined $q->param('t1') )
	{
		if ( $q->param('locus') eq '' ) {
			print "<div class=\"box\" id=\"statusbad\"><p>Please select locus.</p></div>\n";
		} else {
			$self->_run_query;
		}
	} else {
		print "<p />\n";
	}
	return;
}

sub _get_select_items {
	my ( $self, $locus ) = @_;
	my $attributes = $self->{'datastore'}->get_table_field_attributes('sequences');
	my ( @select_items, @order_by );
	foreach (@$attributes) {
		next if $_->{'name'} eq 'locus';
		if ( $_->{'name'} eq 'sender' || $_->{'name'} eq 'curator' || $_->{'name'} eq 'user_id' ) {
			push @select_items, "$_->{'name'} (id)";
			push @select_items, "$_->{'name'} (surname)";
			push @select_items, "$_->{'name'} (first_name)";
			push @select_items, "$_->{'name'} (affiliation)";
		} else {
			push @select_items, $_->{'name'};
		}
		push @order_by, $_->{'name'};
	}
	my %labels;
	foreach my $item (@select_items) {
		( $labels{$item} = $item ) =~ tr/_/ /;
	}
	if ($locus) {
		my $sql =
		  $self->{'db'}->prepare(
"SELECT field,description,value_format,required,length,option_list FROM locus_extended_attributes WHERE locus=? ORDER BY field_order"
		  );
		eval { $sql->execute($locus) };
		$logger->error($@) if $@;
		while ( my ( $field, $desc, $format, $length, $optlist ) = $sql->fetchrow_array ) {
			my $item = "extatt_$field";
			push @select_items, $item;
			( $labels{$item} = $item ) =~ s/^extatt_//;
			$labels{$item} =~ tr/_/ /;
		}
	}
	return ( \@select_items, \%labels, \@order_by );
}

sub _print_table_fields {

	#split so single row can be added by AJAX call
	my ( $self, $locus, $row, $max_rows, $select_items, $labels ) = @_;
	my $q = $self->{'cgi'};
	print "<span style=\"white-space:nowrap\">\n";
	print $q->popup_menu( -name => "s$row", -values => $select_items, -labels => $labels, -class => 'fieldlist' );
	print $q->popup_menu( -name => "y$row", -values => [OPERATORS] );
	print $q->textfield( -name => "t$row", -class => 'value_entry' );
	if ( $row == 1 ) {
		my $next_row = $max_rows ? $max_rows + 1 : 2;
		print "<a id=\"add_table_fields\" href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;"
		  . "page=alleleQuery&amp;row=$next_row&amp;no_header=1\" rel=\"ajax\" class=\"button\">&nbsp;+&nbsp;</a>\n";
		print " <a class=\"tooltip\" title=\"Search values - Empty field values can be searched using the term 'null'. "
		  . "<p /><h3>Number of fields</h3>Add more fields by clicking the '+' button.\">&nbsp;<i>i</i>&nbsp;</a>";
	}
	print "</span>\n";
	return;
}

sub _print_query_interface {
	my ($self) = @_;
	my $q      = $self->{'cgi'};
	my $locus  = $q->param('locus');
	my ( $select_items, $labels, $order_by ) = $self->_get_select_items($locus);
	print "<div class=\"box\" id=\"queryform\">\n";
	my $set_id = $self->get_set_id;
	my ( $display_loci, $cleaned ) = $self->{'datastore'}->get_locus_list( { set_id => $set_id } );
	unshift @$display_loci, '';
	print $q->startform;
	$cleaned->{''} = 'Please select ...';
	print "<p><b>Locus: </b>";
	print $q->popup_menu( -name => 'locus', -id => 'locus', -values => $display_loci, -labels => $cleaned );
	print " <span class=\"comment\">Page will reload when changed</span></p>";
	print $q->hidden($_) foreach qw (db page no_js);

	if ( $q->param('locus') ) {
		my $desc_exists = $self->{'datastore'}->run_simple_query( "SELECT COUNT(*) FROM locus_descriptions WHERE locus=?", $locus )->[0];
		if ($desc_exists) {
			print "<ul><li><a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=locusInfo&amp;locus=$locus\">"
			  . "Further information</a> is available for this locus.</li></ul>\n";
		}
	}
	print "<p>Please enter your search criteria below (or leave blank and submit to return all records).</p>";
	print "<div style=\"white-space:nowrap\">";
	my $table_fields = $q->param('no_js') ? 4 : ( $self->_highest_entered_fields('table_fields') || 1 );
	print "<fieldset>\n<legend>Locus fields</legend>\n";
	my $table_field_heading = $table_fields == 1 ? 'none' : 'inline';
	print "<span id=\"table_field_heading\" style=\"display:$table_field_heading\"><label for=\"c0\">Combine searches with: </label>\n";
	print $q->popup_menu( -name => 'c0', -id => 'c0', -values => [ "AND", "OR" ] );
	print "</span>\n<ul id=\"table_fields\">\n";

	foreach my $i ( 1 .. $table_fields ) {
		print "<li>";
		$self->_print_table_fields( $locus, $i, $table_fields, $select_items, $labels );
		print "</li>\n";
	}
	print "</ul>\n";
	print "</fieldset>\n";
	print "<fieldset class=\"display\">\n";
	print "<ul>\n<li><span style=\"white-space:nowrap\">\n<label for=\"order\" class=\"display\">Order by: </label>\n";
	print $q->popup_menu( -name => 'order', -id => 'order', -values => $order_by, -labels => $labels );
	print $q->popup_menu( -name => 'direction', -values => [qw(ascending descending)], -default => 'ascending' );
	print "</span></li>\n<li>";
	print $self->get_number_records_control;
	print "</li>\n";
	my $locus_clause = $locus ? "&amp;locus=$locus" : '';
	print "</ul><span style=\"float:left\"><a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;"
	  . "page=alleleQuery$locus_clause\" class=\"resetbutton\">Reset</a></span><span style=\"float:right\">";
	print $q->submit( -name => 'submit', -label => 'Submit', -class => 'submit' );
	print "</span></fieldset>\n</div>\n";
	print "<div style=\"white-space:nowrap\"><fieldset><legend>Filter query by</legend>\n";
	print "<ul>\n<li>";
	print $self->get_filter( 'status', [ 'trace checked', 'trace not checked' ], { class => 'display' } );
	print "</li><li>\n";

	if ( ( $self->{'system'}->{'allele_flags'} // '' ) eq 'yes' ) {
		my @flag_values = ( 'any flag', 'no flag', ALLELE_FLAGS );
		print $self->get_filter( 'allele_flag', \@flag_values, { class => 'display' } );
	}
	print "</li></ul>\n</fieldset></div>\n";
	print $q->endform;
	print "</div>\n";
	return;
}

sub _run_query {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	my ( $qry, $qry2 );
	my @errors;
	my $attributes = $self->{'datastore'}->get_table_field_attributes('sequences');
	my $locus      = $q->param('locus');
	$locus = $1 if $locus =~ /^cn_(.+)$/;
	if ( !$self->{'datastore'}->is_locus($locus) ) {
		$logger->error("Invalid locus $locus");
		print "<div class=\"box\" id=\"statusbad\"><p>Invalid locus selected.</p></div>\n";
		return;
	}
	my $locus_info = $self->{'datastore'}->get_locus_info($locus);
	if ( !defined $q->param('query') ) {
		my $andor       = $q->param('c0');
		my $first_value = 1;
		my $extatt_sql  = $self->{'db'}->prepare("SELECT * FROM locus_extended_attributes WHERE locus=? AND field=?");
		foreach my $i ( 1 .. MAX_ROWS ) {
			if ( defined $q->param("t$i") && $q->param("t$i") ne '' ) {
				my $field    = $q->param("s$i");
				my $operator = $q->param("y$i");
				my $text     = $q->param("t$i");
				$self->process_value( \$text );
				if ( $field =~ /^extatt_(.*)$/ ) {

					#search by extended attribute
					$field = $1;
					eval { $extatt_sql->execute( $locus, $field ); };
					$logger->error($@) if $@;
					my $thisfield = $extatt_sql->fetchrow_hashref;
					next
					  if $self->check_format(
						{ field => $field, text => $text, type => $thisfield->{'value_format'}, operator => $operator }, \@errors );
					my $modifier = ( $i > 1 && !$first_value ) ? " $andor " : '';
					$first_value = 0;
					my $std_clause = "$modifier (allele_id IN (SELECT allele_id FROM sequence_extended_attributes "
					  . "WHERE locus=E'$locus' AND field='$field' ";

					if ( $operator eq 'NOT' ) {
						$qry .= $std_clause;
						if ( $text eq 'null' ) {
							$qry .= "))";
						} else {
							$qry .=
							  $thisfield->{'value_format'} eq 'integer'
							  ? "AND NOT CAST(value AS text) = E'$text'))"
							  : "AND NOT upper(value) = upper(E'$text')))";
						}
					} elsif ( $operator eq "contains" ) {
						$qry .= $std_clause;
						$qry .=
						  $thisfield->{'value_format'} eq 'integer'
						  ? "AND CAST(value AS text) LIKE E'\%$text\%'))"
						  : "AND upper(value) LIKE upper(E'\%$text\%')))";
					} elsif ( $operator eq "starts with" ) {
						$qry .= $std_clause;
						$qry .=
						  $thisfield->{'value_format'} eq 'integer'
						  ? "AND CAST(value AS text) LIKE E'$text\%'))"
						  : "AND upper(value) LIKE upper(E'$text\%')))";
					} elsif ( $operator eq "ends with" ) {
						$qry .= $std_clause;
						$qry .=
						  $thisfield->{'value_format'} eq 'integer'
						  ? "AND CAST(value AS text) LIKE E'\%$text'))"
						  : "AND upper(value) LIKE upper(E'\%$text')))";
					} elsif ( $operator eq "NOT contain" ) {
						$qry .= $std_clause;
						$qry .=
						  $thisfield->{'value_format'} eq 'integer'
						  ? "AND NOT CAST(value AS text) LIKE E'\%$text\%'))"
						  : "AND NOT upper(value) LIKE upper(E'\%$text\%')))";
					} elsif ( $operator eq '=' ) {
						if ( $text eq 'null' ) {
							$qry .= "$modifier (allele_id NOT IN (select allele_id FROM sequence_extended_attributes "
							  . "WHERE locus=E'$locus' AND field='$field'))";
						} else {
							$qry .= $std_clause;
							$qry .= $thisfield->{'value_format'} eq 'text' ? "AND upper(value)=upper(E'$text')))" : "AND value=E'$text'))";
						}
					} else {
						if ( $text eq 'null' ) {
							push @errors, "$operator is not a valid operator for comparing null values.";
							next;
						}
						$qry .= $std_clause;
						$qry .=
						  $thisfield->{'value_format'} eq 'integer'
						  ? "AND CAST(value AS int) $operator E'$text'))"
						  : "AND value $operator E'$text'))";
					}
				} else {
					my $thisfield;
					foreach (@$attributes) {
						if ( $_->{'name'} eq $field ) {
							$thisfield = $_;
							last;
						}
					}
					$thisfield->{'type'} ||= 'text';    # sender/curator surname, firstname, affiliation
					$thisfield->{'type'} = $locus_info->{'allele_id_format'} // 'text' if ($thisfield->{'name'} // '') eq 'allele_id';
					if ( none { $field =~ /\($_\)$/ } qw (surname first_name affiliation) ) {
						next
						  if $self->check_format( { field => $field, text => $text, type => $thisfield->{'type'}, operator => $operator },
							\@errors );
					}
					my $modifier = ( $i > 1 && !$first_value ) ? " $andor " : '';
					$first_value = 0;
					if ( $field =~ /(.*) \(id\)$/
						&& !BIGSdb::Utils::is_int($text) )
					{
						push @errors, "$field is an integer field.";
						next;
					}
					$qry .= $modifier;
					if ( any { $field =~ /.* \($_\)/ } qw (id surname first_name affiliation) ) {
						$qry .= $self->search_users( $field, $operator, $text, 'sequences' );
					} else {
						if ( $operator eq 'NOT' ) {
							if ( $text eq 'null' ) {
								$qry .= "$field is not null";
							} else {
								$qry .=
								  $thisfield->{'type'} eq 'text'
								  ? "NOT upper($field) = upper(E'$text')"
								  : "NOT upper($field) = upper(E'$text')";
							}
						} elsif ( $operator eq "contains" ) {
							$qry .=
							  $thisfield->{'type'} eq 'text'
							  ? "upper($field) LIKE upper(E'\%$text\%')"
							  : "upper($field) LIKE upper(E'\%$text\%')";
						} elsif ( $operator eq "starts with" ) {
							$qry .=
							  $thisfield->{'type'} eq 'text'
							  ? "upper($field) LIKE upper(E'$text\%')"
							  : "upper($field) LIKE upper(E'$text\%')";
						} elsif ( $operator eq "ends with" ) {
							$qry .=
							  $thisfield->{'type'} eq 'text'
							  ? "upper($field) LIKE upper(E'\%$text')"
							  : "upper($field) LIKE upper(E'\%$text')";
						} elsif ( $operator eq "NOT contain" ) {
							$qry .=
							  $thisfield->{'type'} eq 'text'
							  ? "NOT upper($field) LIKE upper(E'\%$text\%')"
							  : "NOT CAST($field AS text) LIKE E'\%$text\%'";
						} elsif ( $operator eq '=' ) {
							if ( $text eq 'null' ) {
								$qry .= "$field is null";
							} else {
								$qry .= $thisfield->{'type'} eq 'text' ? "upper($field) = upper(E'$text')" : "$field = E'$text'";
							}
						} else {
							if ( $text eq 'null' ) {
								push @errors, "$operator is not a valid operator for comparing null values.";
								next;
							}
							if ( $field eq 'allele_id' && $locus_info->{'allele_id_format'} eq 'integer' ) {
								$qry .= "CAST($field AS integer) $operator E'$text'";
							} else {
								$qry .= "$field $operator E'$text'";
							}
						}
					}
				}
			}
		}
		$locus =~ s/'/\\'/g;
		$qry ||= '';
		$qry2 = "SELECT * FROM sequences WHERE locus=E'$locus' AND ($qry)";
		foreach (@$attributes) {
			my $param = $_->{'name'} . '_list';
			if ( defined $q->param($param) && $q->param($param) ne '' ) {
				my $value = $q->param($param);
				$self->process_value( \$value );
				if ( $qry2 !~ /WHERE \(\)\s*$/ ) {
					$qry2 .= " AND ";
				} else {
					$qry2 = "SELECT * FROM sequences WHERE locus=E'$locus' AND ";
				}
				$qry2 .= $value eq 'null' ? "$_->{'name'} is null" : "$_->{'name'} = E'$value'";
			}
		}
		$qry2 .= $self->_process_flags;
		$qry2 .= " ORDER BY ";
		if ( $q->param('order') eq 'allele_id' && $locus_info->{'allele_id_format'} eq 'integer' ) {
			$qry2 .= "CAST (" . ( $q->param('order') ) . " AS integer)";
		} else {
			$qry2 .= $q->param('order');
		}
		my $dir = $q->param('direction') eq 'descending' ? 'desc' : 'asc';
		$qry2 .= " $dir;";
	} else {
		$qry2 = $q->param('query');
	}
	my @hidden_attributes;
	push @hidden_attributes, 'c0';
	foreach my $i ( 1 .. MAX_ROWS ) {
		push @hidden_attributes, "s$i", "t$i", "y$i";
	}
	foreach (@$attributes) {
		push @hidden_attributes, $_->{'name'} . '_list';
	}
	push @hidden_attributes, qw(locus no_js);
	if (@errors) {
		print "<div class=\"box\" id=\"statusbad\"><p>Problem with search criteria:</p>\n";
		print "<p>@errors</p></div>\n";
	} else {
		$qry2 =~ s/AND \(\)//;
		$self->paged_display( 'sequences', $qry2, '', \@hidden_attributes );
		print "<p />\n";
	}
	return;
}

sub _process_flags {
	my ($self) = @_;
	my $q      = $self->{'cgi'};
	my $buffer = '';
	if ( ( $q->param('allele_flag_list') // '' ) ne '' && ( $self->{'system'}->{'allele_flags'} // '' ) eq 'yes' ) {
		if ( $q->param('allele_flag_list') eq 'no flag' ) {
			$buffer .= " AND NOT EXISTS (SELECT 1 FROM allele_flags WHERE sequences.locus=allele_flags.locus AND "
			  . "sequences.allele_id=allele_flags.allele_id)";
		} else {
			$buffer .= " AND EXISTS (SELECT 1 FROM allele_flags WHERE sequences.locus=allele_flags.locus AND "
			  . "sequences.allele_id=allele_flags.allele_id";
			if ( any { $q->param('allele_flag_list') eq $_ } ALLELE_FLAGS ) {
				$buffer .= " AND flag = '" . $q->param('allele_flag_list') . "'";
			}
			$buffer .= ')';
		}
	}
	return $buffer;
}

1;
