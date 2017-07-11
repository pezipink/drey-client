import std.stdio;// Simple request-reply broker
import std.concurrency;
import core.time;
import std.format;
import zmqd;
import std.string;
import std.json;
import std.conv;
//import zhelpers;
enum MessageType
  {
    Connect = 0x1,
    Heartbeat = 0x2,
    Data  = 0x3,
    Status = 0x4,
    Universe = 0x5
  }

struct ClientMessage
{
  string client;
  MessageType type;
  string json;  
}

__gshared string id;

string toResponseJson(string response)
{
  JSONValue js;
  js["t"] = "response";
  js["id"] = response;
  return js.toString;
}

class HeapVariant
{
  Variant var;

  public this(T)(T val)
  {
    var = Variant(val); 
  }

  alias var this;

  override string toString()
  {
    return var.toString;
  }
}

class GameObject
{
  int id;
  HeapVariant[string] props;
  string locationKey;
  override string toString()
  {
    return "GameObject " ~ to!string(id);
  }
}

class LocationReference
{
  int id;
  string key;  
  HeapVariant[string] props;
  override string toString()
  {
    return format("LocRef %s", key);
  }
}

class Location
{
  LocationReference[] siblings;
  LocationReference   parent;
  LocationReference[] children; 
  string key;
  HeapVariant[string] props;
  GameObject[int] objects;
  override string toString()
  {
    return key;
  }
}

class GameUniverse
{
  GameObject[int] objects;
  LocationReference[int] locationReferences;  
  Location[string] locations;
}

HeapVariant extractObject(GameUniverse uni, JSONValue js)
{
  // an obj can be one of the following:
  // str
  // int
  // bool
  // encoded ref (also str)
  // array of obj (dont need to support nested arrays)
  switch(js.type())
    {
    case JSON_TYPE.STRING:
      auto s = js.str;
      if(s.startsWith("{") && s.endsWith("}"))
         {
           //encoded object id           
           string s2 = s[1..$-1];
           int id = s2.parse!int;
           return new HeapVariant(uni.objects[id]);
         }
      else if(s.startsWith("(") && s.endsWith(")"))
        {
          //encoded location ref id
          string s2 = s[1..$-1];
          return new HeapVariant(uni.locationReferences[parse!int(s2)]);
        }
      else if(s.startsWith("[") && s.endsWith("]"))
        {
          //encoded location key
          string s2 = s[1..$-1];
          return new HeapVariant(uni.locations[s2]);
        }
      else
        {          
          return new HeapVariant(js.str);
        }
    case JSON_TYPE.INTEGER:
    case JSON_TYPE.UINTEGER:
      return new HeapVariant(js.integer.to!int);
    case JSON_TYPE.TRUE:
      return new HeapVariant(true);
    case JSON_TYPE.FALSE:
      return new HeapVariant(false);
    case JSON_TYPE.ARRAY:
      HeapVariant[] arr;
      foreach(v;js.array)
        {
          arr ~= extractObject(uni, v);
        }
      return new HeapVariant(arr);
    default:
      assert(false);        
    }  
}

void client(Tid parentId)
{
    auto client = Socket(SocketType.dealer);
    client.identity =  id;
    //client.connect("tcp://82.34.41.66:5560");
    client.connect("tcp://localhost:5560");
    
    // Initialize poll set
    auto items = [
        PollItem(client, PollFlags.pollIn),
    ];

    ubyte[] data = [0x1];
    client.send(data);
    writeln("sent connect message");
    MonoTime lastHeart = MonoTime.currTime;
    MonoTime lastServerHeart = MonoTime.currTime;
    auto uni = new GameUniverse();
    while (true)
      {
        Frame frame;
        if(!receiveTimeout
           (dur!"msecs"(1),
            (string s)
            {
              if(s.startsWith("\\c "))
                {
                  //chat
                  s = s[3..$];
                  string msg = "";
                  int index = indexOf(s,":");
                  if(index > -1)
                    {
                      string targ = s[0..index].chomp;
                      string rest = s[index.. $].chomp;
                      writeln("targ ", targ , " rest ", rest);
                      msg = format("{\"t\":\"chat\",\"id\":\"%s\",\"msg\":\"%s\"}", targ, rest);
                    }
                  else
                    {
                      msg = format("{\"t\":\"chat\",\"id\":\"\",\"msg\":\"%s\"}", s);
                    }
                  ubyte[] b = [0x3];
                  client.send(b,true);
                  client.send(msg);
                }
              else if(s.startsWith("\\?"))
                {
                  writeln("Available options : ");
                  writeln("<text> \t\t\t send response to waiting server");
                  writeln("\\c <text>\t\t send global chat message");
                  writeln("\\c <id>:<text>\t\t send chat message to player <id>");
                  writeln("\\status \t\t if the server is waiting for you to reply, it will re-send your options");
                  writeln("\\objects \t\t lists visible game object ids");
                  writeln("\\objects <prop> ... \t lists visible game object ids and their <prop> ... if present");
                  writeln("\\object <id> \t\t displays all information about object <id>");
                  writeln("\\locations \t\t lists visible game location keys");
                  writeln("\\locations <prop> ... \t lists visible game location keys and their <prop> ... if present");
                  writeln("\\location <key> \t displays all visible infromation about location <key>");
                  
                }
              else if(s.startsWith("\\objects"))
                {
                  s = s.strip;
                  if(s == "\\objects")
                    {
                      writeln("the following objects are visible");
                      foreach(k;uni.objects.keys)
                        {
                          auto go = uni.objects[k];
                          writeln(format("id %s : loc %s",go.id, go.locationKey));
                        }
                    }
                  else
                    {
                      // extract props
                      int[string] props;
                      s = s[8..$];
                      foreach(p;s.split(' '))
                        {
                          props[s.strip]=0;
                        }
                      writeln("the following objects are visible2");
                      foreach(k;uni.objects.keys)
                        {
                          auto go = uni.objects[k];
                          writeln(format("id %s : loc %s",go.id, go.locationKey));
                          foreach(p;go.props.byKeyValue)
                            {
                              if(p.key in props)
                                {
                                  writeln(format("%s : %s",p.key, p.value));
                                }
                            }
                        }

                    }
                }
              else if(s.startsWith("\\object"))
                {
                  auto s2 = s = s[8..$];
                  auto id = parse!int(s2);
                  auto go = uni.objects[id];
                  foreach(p;go.props.byKeyValue)
                    {
                      writeln(format("%s : %s",p.key,p.value));
                    }
                      
                  
                }

              else if(s.startsWith("\\universe"))
                {
                  // return list of all visible data from server
                  ubyte[] b = [MessageType.Universe];
                  client.send(b);                  
               }
              else if(s.startsWith("\\status"))
                {
                  // will re-issue a request for this client if
                  // waiting
                  ubyte[] b = [MessageType.Status];
                  client.send(b);  
                }
              else
                {
                  // assume this is a response to a request
                  ubyte[] b = [MessageType.Data];
                  client.send(b,true);
                  client.send(toResponseJson(s));
                }
            }))
          {
            // no client messages need processing, see if the server
            // has anything to say for itself
            poll(items, dur!"msecs"(1));
            if (items[0].returnedEvents & PollFlags.pollIn)
              {
                ClientMessage message;
                bool invalidMessage = false;
                /// first frame will be the id
                frame.rebuild();
                client.receive(frame);
                // see what sort of message this is
                message.type = cast(MessageType)frame.data[0];
                if(message.type == MessageType.Heartbeat)
                  {                
                    lastServerHeart = MonoTime.currTime;
                  }
                else if(message.type == MessageType.Universe)
                  {
                    writeln("rcvd universe repsonse");
                  }
                else if(message.type == MessageType.Status)
                  {
                    writeln("rcvd status response");
                  }
                else if(message.type == MessageType.Data)
                  {
                    frame.rebuild();
                    client.receive(frame);
                    message.json = frame.data.asString.dup;
                    try
                      {
                        JSONValue js = message.json.parseJSON;
                        string type = js["t"].str;
                        writeln(js);
                        switch(type)
                          {
                          case "chat":
                            writeln(js["msg"].str);
                            break;
                          case "request":
                            writeln(js["header"].str);
                            foreach(jsv;js["choices"].array)
                              {
                                if(jsv["id"].type() == JSON_TYPE.INTEGER)
                                  {
                                    writeln(jsv["id"].integer," : ", jsv["text"].str);
                                  }
                                else
                                  {
                                    writeln(jsv["id"].str," : ", jsv["text"].str);
                                  }
                              }
                            break;
                          case "gl":                            
                            auto l = new Location();
                            l.key = js["k"].str;
                            uni.locations[l.key] = l;
                            break;
                          case "glr":                            
                            auto l = new LocationReference();
                            l.id = js["l"].integer.to!int;
                            uni.locationReferences[l.id] = l;
                            break;
                          case "slrk":                            
                            auto i = js["i"].integer.to!int;
                            auto k = js["k"].str;
                            if(i !in uni.locationReferences) assert(false);
                            if(k !in uni.locations) assert(false);
                            uni.locationReferences[i].key = k;
                            break;
                          case "slp":
                            auto lr = js["lr"].integer.to!int;
                            auto p = js["p"].str;
                            if(lr !in uni.locationReferences) assert(false);
                            if(p !in uni.locations) assert(false);
                            uni.locations[p].children ~= uni.locationReferences[lr];
                            break;
                          case "slc":
                            auto lr = js["lr"].integer.to!int;
                            auto c = js["c"].str;
                            if(lr !in uni.locationReferences) assert(false);
                            if(c !in uni.locations) assert(false);
                            uni.locations[c].parent = uni.locationReferences[lr];
                            break;
                          case "sls":
                            auto lr = js["lr"].integer.to!int;
                            auto l = js["l"].str;
                            if(lr !in uni.locationReferences) assert(false);
                            if(l !in uni.locations) assert(false);
                            uni.locations[l].siblings ~= uni.locationReferences[lr];
                            break;
                          case "spl":
                            auto i = js["i"].str;
                            auto k = js["k"].str;
                            auto v = extractObject(uni,js["v"]);
                            if(i !in uni.locations) assert(false, "!");
                            auto loc = uni.locations[i];
                            loc.props[k] = v;
                            break;
                          case "splr":
                            auto i = js["i"].integer.to!int;
                            auto k = js["k"].str;
                            auto v = extractObject(uni,js["v"]);
                            if(i !in uni.locationReferences) assert(false);
                            auto loc = uni.locationReferences[i];
                            loc.props[k] = v;
                            break;
                          case "spg":
                            auto i = js["i"].integer.to!int;
                            auto k = js["k"].str;
                            auto v = extractObject(uni,js["v"]);
                            if(i !in uni.objects) assert(false);
                            auto obj = uni.objects[i];
                            obj.props[k] = v;
                            break;
                          case "aui":
                            auto o = js["o"];
                            auto go = new GameObject;
                            foreach(kvp; o.object.byKeyValue)
                              {
                                if(kvp.key == "id")
                                  {
                                    go.id = kvp.value.integer.to!int;
                                  }
                                else
                                  {
                                    go.props[kvp.key] = extractObject(uni, kvp.value);
                                  }
                              }
                            uni.objects[go.id] = go;
                            break;
                          case "mo":
                            auto l = js["l"].str;
                            auto i = js["o"].integer.to!int;
                            uni.objects[i].locationKey = l;
                            break;
                          default:
                            writeln(js);
                            break;
                                
                          }
                      }
                    catch(Exception e)
                      {
                        writeln(e);
                      }

                  }
                else
                  {                
                    //bad message, swallow it up
                    invalidMessage = true;
                    do {
                      frame.rebuild();
                      client.receive(frame);
                    } while (frame.more);
                    writeln("invalid message received");
                  }
              }
          }
        if(MonoTime.currTime - lastHeart > dur!"msecs"(100))
            {
              // send a heartbeat req to the server
              ubyte[] b = [0x2];
              client.send(b);              
              lastHeart = MonoTime.currTime;
            }

      }
  


}

void main()
{
  writeln("Enter client ID");
  id = readln().chomp;
  auto worker = spawn(&client, thisTid);

// Switch messages between sockets
    while (true) {
      string msg = readln().chomp;
        send(worker, msg);
    }
}
