%% Flood session related stuff.

-record(flood_session, {
          weight        = 0.0    :: number(),
          transport     = <<"">> :: binary(),
          metadata      = []     :: list(),
          actions       = []     :: list(),
          base_actions  = []     :: list(),
          base_sessions = []     :: list()
         }).
