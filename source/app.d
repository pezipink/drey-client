
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
  js["type"] = "response";
  js["id"] = response;
  return js.toString;
}





void client(Tid parentId)
{
    auto client = Socket(SocketType.dealer);
    client.identity =  id;
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
                      msg = format("{\"type\":\"chat\",\"id\":\"%s\",\"msg\":\"%s\"}", targ, rest);
                    }
                  else
                    {
                      msg = format("{\"type\":\"chat\",\"id\":\"\",\"msg\":\"%s\"}", s);
                    }
                  ubyte[] b = [0x3];
                  client.send(b,true);
                  client.send(msg);
                }
              else if(s.startsWith("\\universe"))
                {
                  // return list of all data from server
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
                        string type = js["type"].str;
                        //                        writeln("type ",type);
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
