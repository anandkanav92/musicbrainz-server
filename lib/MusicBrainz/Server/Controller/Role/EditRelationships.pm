package MusicBrainz::Server::Controller::Role::EditRelationships;
use JSON;
use MooseX::Role::Parameterized -metaclass => 'MusicBrainz::Server::Controller::Role::Meta::Parameterizable';
use MusicBrainz::Server::CGI::Expand qw( expand_hash );
use MusicBrainz::Server::Constants qw( $SERIES_ORDERING_TYPE_MANUAL );
use MusicBrainz::Server::Data::Utils qw( model_to_type ref_to_type type_to_model );
use MusicBrainz::Server::Form::Utils qw( build_type_info build_attr_info );
use aliased 'MusicBrainz::Server::WebService::JSONSerializer';

role {
    with 'MusicBrainz::Server::Controller::Role::RelationshipEditor';

    sub serialize_entity {
        my ($source, $type) = @_;

        my $method = "_$type";
        return JSONSerializer->$method($source) if $source;
    }

    sub load_entities {
        my ($c, $source_type, @rels) = @_;

        my $entity_map = {};

        my $link_types = $c->model('LinkType')->get_by_ids(
            map { $_->{link_type_id} } @rels
        );

        for my $field (@rels) {
            my $link_type = $link_types->{$field->{link_type_id}};
            my $forward;
            my $target_type;

            if ($link_type && ($source_type eq $link_type->entity0_type ||
                               $source_type eq $link_type->entity1_type)) {
                $forward = $source_type eq $link_type->entity0_type && !$field->{backward};
                $target_type = $forward ? $link_type->entity1_type : $link_type->entity0_type;
                $field->{link_type} = $link_type;
            } elsif ($field->{text}) {
                # If there's a text field, we can assume it's a URL because
                # that's what the text field is for. Seeding URLs without link
                # types is a reasonable use case given that we autodetect them
                # in the JavaScript.
                $forward = $source_type lt 'url';
                $target_type = 'url';
            }

            $field->{forward} = $forward;
            $field->{target_type} = $target_type;

            if ($target_type ne 'url') {
                push @{ $entity_map->{type_to_model($target_type)} //= [] }, $field->{target};
            }
        }

        for my $model (keys %$entity_map) {
            $entity_map->{$model} = $c->model($model)->get_by_gids(@{ $entity_map->{$model} });
        }

        $c->model('SeriesType')->load(values %{ $entity_map->{'Series'} // {} });

        return $entity_map;
    }

    around 'edit_action' => sub {
        my ($orig, $self, $c, %opts) = @_;

        # Only create/edit forms support relationship editing.
        return $self->$orig($c, %opts) unless $opts{edit_rels};

        my $model = $self->config->{model};
        my $source_type = model_to_type($model);
        my $source = $c->stash->{$self->{entity_name}};

        my $submitted_rel_data = sub {
            my @rels = grep {
                $_ && ($_->{text} || (($_->{target} || $_->{removed}) && $_->{link_type_id}))
            } @_;

            my @result;
            my $entity_map = load_entities($c, $source_type, @rels);

            for (@rels) {
                my $target_type = $_->{target_type};
                my $target;

                next unless $target_type;

                if ($target_type eq 'url') {
                    $target = { name => $_->{text}, entityType => 'url' };
                } elsif ($_->{target}) {
                    my $entity = $entity_map->{type_to_model($target_type)}->{$_->{target}};
                    next unless $entity;
                    $target = serialize_entity($entity, $target_type);
                }

                my $attribute_text_values = {};
                for (@{ $_->{attribute_text_values} // [] }) {
                    $attribute_text_values->{$_->{attribute}} = $_->{text_value};
                }

                push @result, {
                    id          => $_->{relationship_id},
                    linkTypeID  => $_->{link_type_id},
                    removed     => $_->{removed} ? \1 : \0,
                    attributes  => $_->{attributes} // [],
                    beginDate   => $_->{period}->{begin_date} // {},
                    endDate     => $_->{period}->{end_date} // {},
                    ended       => $_->{period}->{ended} ? \1 : \0,
                    target      => $target // { entityType => $target_type },
                    linkOrder   => $_->{link_order} // 0,
                    attributeTextValues => $attribute_text_values,
                };
            }

            # Convert body/query params to the data format used by the
            # JavaScript (same as JSONSerializer->serialize_relationship).
            return \@result;
        };

        my $source_entity = $source ? serialize_entity($source, $source_type) :
                                    { entityType => $source_type };

        if ($source) {
            my @existing_relationships =
                grep {
                    my $lt = $_->link->type;

                    $source->id == $_->entity0_id
                        ? $lt->entity0_cardinality == 0
                        : $lt->entity1_cardinality == 0;

                } sort { $a <=> $b } $source->all_relationships;

            $source_entity->{relationships} =
                JSONSerializer->serialize_relationships(@existing_relationships);
        }

        my $form_name = "edit-$source_type";

        # Grrr. release_group => release-group.
        $form_name =~ s/_/-/;

        if ($c->form_posted) {
            my $body_params = expand_hash($c->req->body_params);

            $source_entity->{submittedRelationships} = $submitted_rel_data->(
                @{ $body_params->{$form_name}->{rel} },
                @{ $form_name eq "edit-url" ? [] : $body_params->{$form_name}->{url} }
            );
        }
        else {
            my $query_params = expand_hash($c->req->query_params);

            my $submitted_relationships = $submitted_rel_data->(
                @{ $query_params->{$form_name}->{rel} },
                @{ $form_name eq "edit-url" ? [] : $query_params->{$form_name}->{url} }
            );

            $source_entity->{submittedRelationships} = $submitted_relationships // [];
        }

        my $json = JSON->new;
        my @link_type_tree = $c->model('LinkType')->get_full_tree;
        my $attr_tree = $c->model('LinkAttributeType')->get_tree;

        $c->stash(
            source_entity   => $json->encode($source_entity),
            attr_info       => $json->encode(build_attr_info($attr_tree)),
            type_info       => $json->encode(build_type_info($c, qr/(^$source_type-|-$source_type$)/, @link_type_tree)),
        );

        my $post_creation = delete $opts{post_creation};

        $opts{post_creation} = sub {
            my ($edit, $form) = @_;

            my $makes_changes = (
                defined $post_creation && $post_creation->($edit, $form)
            );

            $source = $source // $c->model($model)->get_by_id($edit->entity_id);

            my $url_changes = 0;
            if ($form_name ne "edit-url") {
                my @urls = grep { !$_->is_empty } $form->field('url')->fields;
                $url_changes = $self->edit_relationships($c, $form, \@urls, $source);
            }

            my @rels = grep { !$_->is_empty } $form->field('rel')->fields;
            my $rel_changes = $self->edit_relationships($c, $form, \@rels, $source);

            return 1 if $makes_changes || $url_changes || $rel_changes;
        };

        return $self->$orig($c, %opts);
    };

    method 'edit_relationships' => sub {
        my ($self, $c, $form, $fields, $source) = @_;

        return unless @$fields;

        my @edits;
        my @field_values = map { $_->value } @$fields;
        my $entity_map = load_entities($c, ref_to_type($source), @field_values);
        my %reordered_relationships;

        for my $field (@field_values) {
            my %args;
            my $link_type = $field->{link_type};

            if (my $period = $field->{period}) {
                $args{begin_date} = $period->{begin_date} if $period->{begin_date};
                $args{end_date} = $period->{end_date} if $period->{end_date};
                $args{ended} = $period->{ended} if $period->{ended};
            }

            $args{attributes} = $field->{attributes} if $field->{attributes};

            if ($field->{attribute_text_values}) {
                my %attribute_text_values;

                for (@{ $field->{attribute_text_values} // [] }) {
                    $attribute_text_values{$_->{attribute}} = $_->{text_value};
                }

                $args{attribute_text_values} = \%attribute_text_values;
            }

            $args{ended} ||= 0;

            unless ($field->{removed}) {
                $args{link_type} = $link_type;

                my $target;

                if ($field->{text}) {
                    $target = $c->model('URL')->find_or_insert($field->{text});
                } elsif ($field->{target}) {
                    $target = $entity_map->{type_to_model($field->{target_type})}->{$field->{target}};
                    next unless $target;
                }

                $args{entity0} = $field->{forward} ? $source : $target;
                $args{entity1} = $field->{forward} ? $target : $source;
                $args{link_order} = $field->{link_order} // 0;
            }

            if ($field->{relationship_id}) {
                my $relationship = $c->model('Relationship')->get_by_id(
                   $link_type->entity0_type, $link_type->entity1_type, $field->{relationship_id}
                );

                defined $relationship or next; # MBS-7354: relationship may have been deleted after the form was created

                $args{relationship} = $relationship;
                $c->model('Link')->load($relationship);
                $c->model('LinkType')->load($relationship->link);
                $c->model('Relationship')->load_entities($relationship);

                if ($field->{removed}) {
                    push @edits, $self->delete_relationship($c, $form, %args);
                } else {
                    push @edits, $self->try_and_edit($c, $form, %args);

                    my $orderable_direction = $link_type->orderable_direction;

                    if ($orderable_direction != 0 && $field->{link_order} != $relationship->link_order) {
                        my $orderable_entity = $orderable_direction == 1 ? $relationship->entity1 : $relationship->entity0;
                        my $unorderable_entity = $orderable_direction == 1 ? $relationship->entity0 : $relationship->entity1;
                        my $is_series = $unorderable_entity->isa('MusicBrainz::Server::Entity::Series');

                        if (!$is_series || $unorderable_entity->ordering_type_id == $SERIES_ORDERING_TYPE_MANUAL) {
                            my $key = join "-", $link_type->id, $unorderable_entity->id;

                            push @{ $reordered_relationships{$key} //= [] }, {
                                relationship => $relationship,
                                new_order => $field->{link_order},
                                old_order => $relationship->link_order,
                            };
                        }
                    }
                }
            } else {
                push @edits, $self->try_and_insert($c, $form, %args);
            }
        }

        while (my ($key, $relationship_order) = each %reordered_relationships) {
            my ($link_type_id) = split /-/, $key;

            push @edits, $self->reorder_relationships(
                $c, $form,
                link_type_id => $link_type_id,
                relationship_order => $relationship_order,
            );
        }

        return @edits;
    };
};

1;
